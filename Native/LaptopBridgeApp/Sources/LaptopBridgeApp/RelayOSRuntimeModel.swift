// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSRuntimeModel.swift
import Foundation
import AppKit
import SwiftUI
import Security
import Darwin

@MainActor
final class BridgeModel: ObservableObject {
    static let shared = BridgeModel()
    @Published var running = false
    @Published var mcpHealth: MCPHealthStatus = .unreachable
    @Published var tunnelRunning = false
    @Published var tunnelHealth: TunnelHealthStatus = .stopped
    @Published var serviceNotice = ""
    @Published var emergencyStop = false
    @Published var endpoint = "Not configured"
    @Published var geminiConnected = false
    @Published var chatGPTConnected = false
    @Published var screenGuidance = false
    @Published var projectTools = false
    @Published var ngrokToken = ""
    @Published var ngrokDomainValue = ""
    @Published var ngrokInstallState = ""
    @Published var connectedClients: [String] = []
    @Published var permissionGrants: [[String: Any]] = []
    @Published var commandGrants: [SavedCommandGrant] = []
    @Published var commandJobs: [CommandJobEntry] = []
    @Published var selectedCommandJobID: String?
    @Published var commandJobOutput = ""
    @Published var commandJobError: String?
    private var commandJobStdoutOffset = 0
    private var commandJobStderrOffset = 0
    private var commandJobPollInFlight = false
    private var commandOutputPollInFlight = false
    @Published var commandGrantsBusy = false
    @Published var commandGrantDuplicateCount = 0
    @Published var commandGrantsError: String?


    private let configURL: URL
    private let supervisor = ServiceSupervisor()
    private let tunnelMonitor = NgrokTunnelMonitor()
    private let serverSlot = ManagedProcessSlot()
    private let tunnelSlot = ManagedProcessSlot()
    private var server: Process? {
        get { serverSlot.process }
        set { serverSlot.assign(newValue) }
    }
    private var tunnel: Process? {
        get { tunnelSlot.process }
        set { tunnelSlot.assign(newValue) }
    }
    private var shouldMaintainServices = false
    private var approvalTimer: DispatchSourceTimer?
    @Published var approvalInbox: [ApprovalInboxItem] = []
    @Published var approvalNavigationRequest = 0
    func showApprovalCenter() { approvalNavigationRequest += 1 }
    @Published var approvalActivity: [ApprovalActivityEntry] = []
    @Published var approvalCenterError: String?
    @Published var approvalDecisionInFlight: String?
    private var inboxPollInFlight = false
    private let arrivalTracker = ApprovalArrivalTracker()
    private var terminationObserver: NSObjectProtocol?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".laptop-bridge/config.json")
        loadConfig()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.shutdownServices() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func shutdownServices() {
        shouldMaintainServices = false
        approvalTimer?.cancel()
        approvalTimer = nil
        // Release the instance lock only after owned services have exited.
        // Otherwise the replacement might adopt a still-listening server that
        // is about to disappear as the previous app finishes terminating.
        stopOwnedProcess(tunnel)
        stopOwnedProcess(server)
        tunnel = nil
        server = nil
        running = false
        tunnelRunning = false
        tunnelHealth = .stopped
        mcpHealth = .unreachable
        supervisor.resetForManualRestart()
    }

    private func stopOwnedProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            // Only signal the specific subprocess created by this instance.
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let base = json["public_base_url"] as? String, base.hasPrefix("https://"), !base.contains("/docs/"), !base.isEmpty { endpoint = base + "/mcp" }
        if let caps = json["capabilities"] as? [String: Any] {
            screenGuidance = caps["screen_guidance"] as? Bool ?? false
            projectTools = caps["project_tools"] as? Bool ?? false
        }
    }

    private nonisolated func approvalExecutable() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Runtime/RelayOSApprovals").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return DevelopmentRuntimeLocator.pythonExecutable()?.path
    }

    private nonisolated func setApprovalWorkingDirectory(_ process: Process, executable: String) {
        // A downloaded bundle has no repository checkout. Point bundled
        // approval helpers at the user's home directory instead of the
        // developer-only path, which otherwise makes Process.run() fail before
        // the approval dialog can be shown.
        if executable.contains("/Contents/Resources/Runtime/") {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        } else {
            process.currentDirectoryURL = DevelopmentRuntimeLocator.projectRoot()
        }
    }

    /// A separately supervised local server (for example, the LaunchAgent
    /// used by development installs) already owns this endpoint. Starting a
    /// second helper would make it exit on EADDRINUSE and falsely toggle the
    /// companion UI between Running and Stopped.
    private func localServerIsListening() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(8765).bigEndian
        guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func startServices() {
        // A losing app instance must never launch the MCP server, tunnel, or approval workers.
        guard SingleInstanceCoordinator.shared.ownsLock else { return }
        shouldMaintainServices = true
        if approvalTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkOAuthApprovalsInBackground() }
            timer.resume()
            approvalTimer = timer
            refreshConnectedClients()
            refreshPermissionGrants()
        }
        guard server == nil else { return }
        if localServerIsListening() {
            // Port ownership alone is not a valid RelayOS health signal.
            // The asynchronous authenticated health probe decides whether to
            // adopt this listener and start ngrok.
            running = false
            return
        }
        guard supervisor.mayLaunchServer() else { return }
        let process = Process()
        let bundledHelper = Bundle.main.resourceURL?
            .appendingPathComponent("Runtime/RelayOSMCPServer")
            .path
        let candidates = [bundledHelper, DevelopmentRuntimeLocator.pythonExecutable()?.path].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            supervisor.serverLaunchFailed()
            running = false
            NSLog("RelayOS MCP helper not found. Install the packaged app or set RELAYOS_DEV_ROOT.")
            return
        }
        let isBundledHelper = bundledHelper == executable
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = isBundledHelper ? [] : ["-m", "laptop_bridge.server"]
        // The packaged app is launched from Finder/menu bar, so its current
        // directory is not the repository. Set it explicitly so Python can
        // resolve the laptop_bridge package and its resources.
        if !isBundledHelper {
            process.currentDirectoryURL = DevelopmentRuntimeLocator.projectRoot()
        }
        var environment = ProcessInfo.processInfo.environment
        // Keep the current public Python OAuth/MCP listener reachable while
        // the Swift edge proxy is introduced incrementally.
        environment["LAPTOP_BRIDGE_MCP_PORT"] = "8765"
        process.environment = environment
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.serverSlot.clearIfMatches(finished) else { return }
                self.running = false
                self.mcpHealth = .unreachable
                if self.shouldMaintainServices {
                    self.supervisor.serverDidExit()
                }
            }
        }
        do {
            try process.run()
            server = process
            // Wait for the authenticated local status response before marking
            // the server healthy or opening a public tunnel.
            running = false
        } catch {
            server = nil
            running = false
            supervisor.serverLaunchFailed()
            NSLog("RelayOS could not start MCP helper: %@", error.localizedDescription)
        }
    }

    func restartServices() {
        let ownsServer = server != nil
        stopOwnedProcess(tunnel)
        stopOwnedProcess(server)
        server = nil
        tunnel = nil
        running = false
        tunnelRunning = false
        tunnelHealth = .stopped
        guard SingleInstanceCoordinator.shared.ownsLock else { return }
        supervisor.resetForManualRestart()
        mcpHealth = .unreachable
        if ownsServer {
            startServices()
        } else {
            // The next health probe must authenticate the external listener.
            running = false
        }
    }

    func restartPythonServer() {
        let owned = server != nil
        stopOwnedProcess(server)
        server = nil
        running = false
        mcpHealth = .unreachable
        supervisor.resetForManualRestart()
        if owned { startServices() }
    }

    func startTunnelIfConfigured() {
        guard SingleInstanceCoordinator.shared.ownsLock, mcpHealth == .healthy,
              supervisor.mayLaunchTunnel() else { return }
        guard tunnel == nil, let token = TokenStore.read() else { return }
        let executable = ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        // An empty domain uses ngrok's free generated HTTPS hostname. A
        // reserved domain is only passed when explicitly configured.
        let domain = ngrokDomain()
        // `--pooling-enabled` is not a supported `ngrok http` CLI flag. It
        // caused free endpoints to exit immediately, leaving public MCP shown
        // as stopped. A plain HTTP endpoint lets ngrok allocate its HTTPS URL.
        process.arguments = domain.map { ["http", "127.0.0.1:8765", "--url", "https://\($0)"] } ?? ["http", "127.0.0.1:8765"]
        var environment = ProcessInfo.processInfo.environment
        environment["NGROK_AUTHTOKEN"] = token
        process.environment = environment
        // Drain logs without trusting a URL parsed from stdout. Only the
        // inspector's tunnel forwarded to 127.0.0.1:8765 can be adopted.
        process.standardInput = Pipe()
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.tunnelSlot.clearIfMatches(finished) else { return }
                self.tunnelRunning = false
                self.tunnelHealth = .stopped
                if self.shouldMaintainServices {
                    self.supervisor.tunnelDidExit()
                }
            }
        }
        do {
            supervisor.markTunnelStarting()
            try process.run()
            tunnel = process
            tunnelRunning = process.isRunning
            tunnelHealth = .connecting
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            tunnel = nil
            tunnelRunning = false
            tunnelHealth = .stopped
            supervisor.tunnelDidExit()
            NSLog("RelayOS could not start ngrok: %@", error.localizedDescription)
            return
        }
        // The periodic authenticated tunnel monitor discovers the hostname.
        // Avoid one-shot inspector requests that lose races with ngrok startup.
    }

    private func ngrokDomain() -> String? {
        guard let data = try? Data(contentsOf: configURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ngrok = json["ngrok"] as? [String: Any], let domain = ngrok["domain"] as? String, !domain.isEmpty else { return nil }
        return domain
    }

    private func adoptNgrokEndpoint(_ origin: String) {
        let clean = origin.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard clean.hasPrefix("https://") else { return }
        endpoint = clean + "/mcp"
        guard let data = try? Data(contentsOf: configURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // A repeated inspector/log event is not a reason to restart MCP.
        guard json["public_base_url"] as? String != clean else { return }
        json["public_base_url"] = clean
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? output.write(to: configURL, options: .atomic)
        }
        restartPythonServer()
    }

    func saveCapabilities() {
        guard let data = try? Data(contentsOf: configURL), var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["capabilities"] = ["system_status": true, "screen_guidance": screenGuidance, "project_tools": projectTools]
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]), let dir = configURL.deletingLastPathComponent() as URL? {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? output.write(to: configURL, options: .atomic)
        }
        restartServices()
    }

    func copyEndpoint() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(endpoint, forType: .string) }
    func setEmergencyStop(_ value: Bool) {
        guard emergencyStop != value else { return }
        guard let python = approvalExecutable() else {
            showSecurityError("RelayOS authorization helper is unavailable.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "set-emergency-stop", value ? "true" : "false"]
        setApprovalWorkingDirectory(process, executable: python)
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try pipe.fileHandleForReading.readToEnd(),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let confirmed = payload["emergency_stop"] as? Bool,
                  confirmed == value else {
                showSecurityError("The agent did not confirm the requested emergency-stop state.")
                return
            }
            emergencyStop = confirmed
        } catch {
            showSecurityError("Could not update emergency stop: \(error.localizedDescription)")
        }
    }

    private func showSecurityError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "RelayOS security action failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    nonisolated private func refreshEmergencyStop() {
        guard let python = approvalExecutable() else { return }
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "emergency-stop-status"]
        setApprovalWorkingDirectory(process, executable: python)
        process.standardOutput = pipe; try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["emergency_stop"] as? Bool else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.emergencyStop != enabled {
                self?.emergencyStop = enabled
            }
        }
    }

    func installNgrok() {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ngrok") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ngrok") {
            ngrokInstallState = "ngrok is already installed."
            return
        }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else { ngrokInstallState = "Homebrew was not found. Install it from brew.sh."; return }
        ngrokInstallState = "Installing ngrok…"
        let process = Process(); process.executableURL = URL(fileURLWithPath: brew); process.arguments = ["install", "ngrok/ngrok/ngrok"]
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.ngrokInstallState = process.terminationStatus == 0 ? "ngrok installed successfully." : "ngrok installation failed. Try again or use Terminal."
            }
        }
        try? process.run()
    }

    func configureNgrok() {
        let domain = ngrokDomainValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !ngrokToken.isEmpty else { return }
        guard domain.isEmpty || (domain.contains(".") && !domain.contains("/")) else { return }
        TokenStore.write(ngrokToken)
        var json = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: configURL)) ?? Data())) as? [String: Any] ?? [:]
        json["public_base_url"] = domain.isEmpty ? "" : "https://\(domain)"
        json["active_transport"] = "ngrok"
        json["setup_complete"] = true
        json["ngrok"] = ["enabled": true, "domain": domain, "region": "", "config_path": "", "agent_version": ""]
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: configURL, options: .atomic) }
        endpoint = domain.isEmpty ? "Waiting for ngrok…" : "https://\(domain)/mcp"
        ngrokToken = ""
        restartServices()
    }

    nonisolated private func refreshConnectedClients() {
        guard let python = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-grants"]
            self?.setApprovalWorkingDirectory(process, executable: python)
            process.standardOutput = pipe
            try? process.run(); process.waitUntilExit()
            guard let data = try? pipe.fileHandleForReading.readToEnd(),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let names = items.compactMap { $0["client_name"] as? String }
            DispatchQueue.main.async { [weak self] in self?.connectedClients = names }
        }
    }

    nonisolated private func refreshPermissionGrants() {
        guard let python = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-permissions"]
            self?.setApprovalWorkingDirectory(process, executable: python)
            process.standardOutput = pipe; try? process.run(); process.waitUntilExit()
            guard let data = try? pipe.fileHandleForReading.readToEnd(), let grants = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            DispatchQueue.main.async { [weak self] in self?.permissionGrants = grants }
        }
    }

    func revokePermission(_ id: String) {
        guard let python = approvalExecutable() else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-m", "laptop_bridge.approvals", "revoke-permission", id]
        setApprovalWorkingDirectory(process, executable: python)
        try? process.run(); process.waitUntilExit(); refreshPermissionGrants()
    }

    func refreshCommandJobs() {
        guard let helper = approvalExecutable(), !commandJobPollInFlight else { return }
        commandJobPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-command-jobs"]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
                let jobs = try JSONDecoder().decode([CommandJobEntry].self, from: data)
                Task { @MainActor [weak self] in
                    self?.commandJobs = jobs
                    self?.commandJobPollInFlight = false
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.commandJobError = error.localizedDescription
                    self?.commandJobPollInFlight = false
                }
            }
        }
    }

    func selectCommandJob(_ id: String) {
        guard selectedCommandJobID != id else { return }
        selectedCommandJobID = id
        commandJobStdoutOffset = 0
        commandJobStderrOffset = 0
        commandJobOutput = ""
        commandJobError = nil
        refreshCommandJobOutput()
    }

    func refreshCommandJobOutput() {
        guard let jobID = selectedCommandJobID,
              !commandOutputPollInFlight,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let encodedID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return }
        var components = URLComponents(string: "http://127.0.0.1:8765/control/command-job-output/\(encodedID)")!
        let stdoutOffset = commandJobStdoutOffset
        let stderrOffset = commandJobStderrOffset
        components.queryItems = [
            URLQueryItem(name: "stdout_offset", value: String(stdoutOffset)),
            URLQueryItem(name: "stderr_offset", value: String(stderrOffset))
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        commandOutputPollInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commandOutputPollInFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let output = try JSONDecoder().decode(CommandJobOutput.self, from: data)
                guard self.selectedCommandJobID == jobID else { return }
                self.commandJobStdoutOffset = output.stdoutOffset
                self.commandJobStderrOffset = output.stderrOffset
                if !output.stdout.isEmpty {
                    self.commandJobOutput += output.stdout
                }
                if !output.stderr.isEmpty {
                    self.commandJobOutput += output.stderr
                }
                if self.commandJobOutput.count > 80_000 {
                    self.commandJobOutput = String(self.commandJobOutput.suffix(80_000))
                }
                if output.outputUnavailable && self.commandJobOutput.isEmpty {
                    self.commandJobOutput = "Output unavailable after MCP server restart."
                }
            } catch {
                self.commandJobError = error.localizedDescription
            }
        }
    }

    func cancelCommandJob(_ jobID: String) {
        guard let helper = approvalExecutable() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "cancel-command-job", jobID]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
                Task { @MainActor [weak self] in self?.refreshCommandJobs() }
            } catch {
                Task { @MainActor [weak self] in
                    self?.commandJobError = error.localizedDescription
                }
            }
        }
    }

    /// Read-only grant inspection through the companion's bundled local helper.
    /// The MCP client cannot change any grant through this UI.
    func refreshCommandGrants() {
        guard let executable = approvalExecutable() else {
            commandGrantsError = "RelayOS approval helper could not be found."
            return
        }
        guard !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-command-grants"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "Could not read command grants."])
                }
                let grants = try JSONDecoder().decode([SavedCommandGrant].self, from: data)
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrants = grants
                    self?.commandGrantsBusy = false
                    self?.refreshCommandGrantDuplicateCount()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }

    /// Preview genuine identical-scope duplicates; never infer duplicates
    /// from matching executable names alone.
    func refreshCommandGrantDuplicateCount() {
        guard let executable = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "command-grant-duplicates"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let data = try output.fileHandleForReading.readToEnd(),
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let duplicates = result["duplicates"] else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantDuplicateCount = duplicates
                }
            } catch {
                // A temporary read failure must not revoke or change anything.
            }
        }
    }

    /// Triggered solely by the user's confirmation in CommandPermissionsView.
    func cleanupDuplicateCommandGrants() {
        guard let executable = approvalExecutable(), !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "cleanup-command-grant-duplicates"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "Could not clean duplicate approvals."])
                }
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsBusy = false
                    self?.refreshCommandGrants()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }

    /// Revoke a single approved grant only after confirmation in the native view.
    func revokeCommandGrant(_ id: String) {
        guard let executable = approvalExecutable() else {
            commandGrantsError = "RelayOS approval helper could not be found."
            return
        }
        guard !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "revoke-command-grant", id]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "The approval could not be revoked."])
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.commandGrants.removeAll { $0.id == id }
                    self.commandGrantsBusy = false
                    self.refreshCommandGrants()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }

    private func maintainServicesIfNeeded() {
        guard shouldMaintainServices, SingleInstanceCoordinator.shared.ownsLock else { return }

        if supervisor.beginProbe() {
            let observedGeneration = supervisor.generation
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await self.supervisor.probe()
                guard self.shouldMaintainServices,
                      SingleInstanceCoordinator.shared.ownsLock,
                      self.supervisor.finishProbe(status, generation: observedGeneration)
                else { return }
                self.mcpHealth = status
                self.running = status == .healthy
                if status != .healthy, self.tunnel != nil {
                    self.tunnelHealth = .connecting
                }
                self.recoverServicesIfNeeded()
            }
        }
        if tunnel != nil, mcpHealth == .healthy, supervisor.beginTunnelProbe() {
            let observedTunnel = tunnel
            let generation = supervisor.tunnelGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.tunnelMonitor.probe()
                guard self.shouldMaintainServices,
                      SingleInstanceCoordinator.shared.ownsLock,
                      self.tunnel === observedTunnel,
                      self.supervisor.finishTunnelProbe(result.status, generation: generation)
                else { return }
                self.tunnelHealth = result.status
                if let publicURL = result.publicURL {
                    self.adoptNgrokEndpoint(publicURL.absoluteString)
                }
                self.recoverServicesIfNeeded()
            }
        }
        recoverServicesIfNeeded()
    }

    private func recoverServicesIfNeeded() {
        guard shouldMaintainServices, SingleInstanceCoordinator.shared.ownsLock else { return }
        // Only recycle processes started by this app; do not kill a competing
        // listener on 8765 or an unrelated process using ngrok's inspector.
        if supervisor.shouldRecycleOwnedServer, let ownedServer = server {
            serviceNotice = "Local MCP helper stopped responding; restarting it."
            stopOwnedProcess(ownedServer)
            server = nil
            running = false
            mcpHealth = .unreachable
            supervisor.serverDidExit()
        }
        if supervisor.shouldRecycleOwnedTunnel, let ownedTunnel = tunnel {
            serviceNotice = "ngrok tunnel has not been reachable; reconnecting."
            stopOwnedProcess(ownedTunnel)
            tunnel = nil
            tunnelRunning = false
            tunnelHealth = .stopped
            supervisor.tunnelDidExit()
        }
        if server == nil, !localServerIsListening(), supervisor.mayLaunchServer() {
            startServices()
        }
        if tunnel == nil, mcpHealth == .healthy, supervisor.mayLaunchTunnel() {
            startTunnelIfConfigured()
        }
        if mcpHealth == .healthy && tunnelHealth == .healthy {
            serviceNotice = ""
        }
    }

    /// Poll through the local helper, never through the public MCP interface.
    /// All pending requests are retained in a single inbox, not just the first.
    func refreshApprovalInbox() {
        guard !inboxPollInFlight, let helper = approvalExecutable() else { return }
        inboxPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-inbox"]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = pipe
            do {
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOSInbox", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not load approvals."])
                }
                let items = try JSONDecoder().decode([ApprovalInboxItem].self, from: data)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let newlyArrived = self.arrivalTracker.newlyObserved(items)
                    self.approvalInbox = items
                    self.approvalCenterError = nil
                    self.inboxPollInFlight = false
                    if !newlyArrived.isEmpty {
                        ApprovalSound.playIfEnabled()
                        for item in newlyArrived { ApprovalArrivalNotification.deliver(item) }
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.approvalCenterError = error.localizedDescription
                    self?.inboxPollInFlight = false
                }
            }
        }
    }

    func refreshApprovalActivity(search: String = "") {
        guard let helper = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "activity-history",
                                 "--limit", "150", "--search", search]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return }
                let events = try JSONDecoder().decode([ApprovalActivityEntry].self, from: data)
                Task { @MainActor [weak self] in self?.approvalActivity = events }
            } catch {
                Task { @MainActor [weak self] in self?.approvalCenterError = error.localizedDescription }
            }
        }
    }

    /// Explicit local user action. A backend refusal leaves the request in the
    /// inbox and surfaces an error; it never claims that approval succeeded.
    func decideApproval(_ item: ApprovalInboxItem, decision: String) {
        guard approvalDecisionInFlight == nil, !item.isExpired,
              let helper = approvalExecutable() else {
            approvalCenterError = "Request expired or another decision is in progress."
            refreshApprovalInbox()
            return
        }
        guard ["once", "session", "persistent", "deny"].contains(decision),
              (!item.isOAuth || decision == "once" || decision == "deny") else { return }
        approvalDecisionInFlight = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals",
                                 "decide-inbox", item.id, decision]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOSInbox", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Request expired, was denied, or could not be decided."])
                }
                Task { @MainActor [weak self] in
                    self?.approvalDecisionInFlight = nil
                    self?.approvalInbox.removeAll { $0.id == item.id }
                    self?.approvalCenterError = nil
                    self?.refreshApprovalInbox()
                    self?.refreshApprovalActivity()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.approvalDecisionInFlight = nil
                    self?.approvalCenterError = error.localizedDescription
                    self?.refreshApprovalInbox()
                }
            }
        }
    }

    nonisolated func checkOAuthApprovalsInBackground() {
        Task { @MainActor [weak self] in
            self?.maintainServicesIfNeeded()
            self?.refreshApprovalInbox()
        }
        // Keep existing status/permission polling independent of the inbox.
        refreshConnectedClients()
        refreshPermissionGrants()
        refreshEmergencyStop()
    }

}

enum Keychain {
    static let service = "rw.shangazi.laptop-bridge"
    static func read(account: String) -> String? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum TokenStore {
    private static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".laptop-bridge/ngrok.token") }
    static func read() -> String? {
        if let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Keychain.read(account: "ngrok_authtoken")
    }
    static func write(_ value: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
