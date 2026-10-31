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

    private let configURL: URL
    private let supervisor = ServiceSupervisor()
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
    private var visibleApprovalID: String?
    private var handledApprovalIDs: [String: Date] = [:]
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
        process.arguments = domain.map { ["http", "127.0.0.1:8765", "--url", "https://\($0)"] } ?? ["http", "127.0.0.1:8765", "--pooling-enabled"]
        var environment = ProcessInfo.processInfo.environment
        environment["NGROK_AUTHTOKEN"] = token
        process.environment = environment
        // Detach the agent from the terminal that launched the menu-bar app;
        // otherwise ngrok can receive job-control signals and become stopped.
        process.standardInput = Pipe()
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8), let range = text.range(of: "https://[^\\s]+\\.ngrok-free\\.dev[^\\s]*", options: .regularExpression) else { return }
            let url = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'`,"))
            Task { @MainActor [weak self] in self?.adoptNgrokEndpoint(url) }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.tunnelSlot.clearIfMatches(finished) else { return }
                self.tunnelRunning = false
                if self.shouldMaintainServices {
                    self.supervisor.tunnelDidExit()
                }
            }
        }
        do {
            try process.run()
            tunnel = process
            tunnelRunning = process.isRunning
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            tunnel = nil
            tunnelRunning = false
            supervisor.tunnelDidExit()
            NSLog("RelayOS could not start ngrok: %@", error.localizedDescription)
            return
        }
        // The agent may emit no stdout when launched from a GUI. Ask its
        // local inspector API for the assigned free hostname as a fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshNgrokEndpoint() }
    }

    private func refreshNgrokEndpoint() {
        guard tunnelRunning, let url = URL(string: "http://127.0.0.1:4040/api/tunnels") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tunnels = object["tunnels"] as? [[String: Any]], let publicURL = tunnels.compactMap({ $0["public_url"] as? String }).first else { return }
            Task { @MainActor [weak self] in self?.adoptNgrokEndpoint(publicURL) }
        }.resume()
    }

    private func ngrokDomain() -> String? {
        guard let data = try? Data(contentsOf: configURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ngrok = json["ngrok"] as? [String: Any], let domain = ngrok["domain"] as? String, !domain.isEmpty else { return nil }
        return domain
    }

    private func adoptNgrokEndpoint(_ origin: String) {
        let clean = origin.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard clean.hasPrefix("https://") else { return }
        endpoint = clean + "/mcp"
        supervisor.tunnelReady()
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

    func checkOAuthApprovals() {
        guard visibleApprovalID == nil else { return }
        guard let python = approvalExecutable() else { return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-oauth"]
        setApprovalWorkingDirectory(process, executable: python)
        process.standardOutput = pipe
        try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = items.first,
              let requestID = item["request_id"] as? String else { return }
        visibleApprovalID = requestID
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.level = .floating
        ApprovalSound.playIfEnabled()
        alert.messageText = "Approve MCP connection?"
        alert.informativeText = "An MCP client is requesting access to RelayOS. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let decisionProcess = Process(); decisionProcess.executableURL = URL(fileURLWithPath: python)
        decisionProcess.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        setApprovalWorkingDirectory(decisionProcess, executable: python)
        try? decisionProcess.run(); decisionProcess.waitUntilExit()
        visibleApprovalID = nil
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
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
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
                self.recoverServicesIfNeeded()
            }
        }
        recoverServicesIfNeeded()
    }

    private func recoverServicesIfNeeded() {
        guard shouldMaintainServices, SingleInstanceCoordinator.shared.ownsLock else { return }
        // A third-party or unauthorized local listener must never be adopted
        // or replaced by terminating its process.
        if server == nil, !localServerIsListening(), supervisor.mayLaunchServer() {
            startServices()
        }
        // Only publish a tunnel after authentication of the local MCP server.
        if tunnel == nil, mcpHealth == .healthy, supervisor.mayLaunchTunnel() {
            startTunnelIfConfigured()
        }
    }

    nonisolated func checkOAuthApprovalsInBackground() {
        Task { @MainActor [weak self] in self?.maintainServicesIfNeeded() }
        refreshConnectedClients()
        refreshPermissionGrants()
        refreshEmergencyStop()
        checkPendingPermissionRequests()
        guard let python = approvalExecutable() else { return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-oauth"]
        setApprovalWorkingDirectory(process, executable: python)
        process.standardOutput = pipe
        try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = items.first,
              let requestID = item["request_id"] as? String else { return }
        let clientName = (item["client_name"] as? String) ?? "MCP client"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibleApprovalID == nil else { return }
            self.handledApprovalIDs = self.handledApprovalIDs.filter { Date().timeIntervalSince($0.value) < 300 }
            guard self.handledApprovalIDs[requestID] == nil else { return }
            self.handledApprovalIDs[requestID] = Date()
            self.presentApproval(requestID: requestID, clientName: clientName, python: python)
        }
    }

    nonisolated private func checkPendingPermissionRequests() {
        guard let python = approvalExecutable() else { return }
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-pending-json"]
        setApprovalWorkingDirectory(process, executable: python)
        process.standardOutput = pipe; try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let item = items.first, let id = item["request_id"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibleApprovalID == nil, self.handledApprovalIDs[id] == nil else { return }
            self.handledApprovalIDs[id] = Date(); self.presentPermission(requestID: id, item: item, python: python)
        }
    }

    private func presentPermission(requestID: String, item: [String: Any], python: String) {
        ApprovalSound.playIfEnabled()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.window.level = .floating; alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let kind = item["kind"] as? String ?? "operation"; let target = item["target"] as? String ?? "requested resource"
        let argv = item["argv"] as? [String] ?? []
        let context = item["context"] as? [String: Any] ?? [:]
        let arguments = argv.joined(separator: " ")
        let cwd = context["cwd"] as? String ?? "Not specified"
        let requested = context["requested_grant"] as? String ?? "once"
        let family = context["command_family"] as? String
        let prefix = context["scope_prefix"] as? [String]
        let familyLabel = family == "git:add" ? "git add" : nil
        let reusableLabel = prefix?.joined(separator: " ") ?? familyLabel
        let operationScope = reusableLabel.map {
            "Session / Always: only commands starting with '\($0)' in this project and working directory. Arguments after that prefix may change."
        } ?? "Session / Always: only the exact command and working directory shown above."
        alert.messageText = reusableLabel.map { "Approve \($0)?" } ?? "Approve \(kind)?"
        alert.informativeText = """
        Target: \(target)
        Exact requested command: \(arguments.isEmpty ? "(none)" : arguments)
        Working directory: \(cwd)
        Client requested: \(requested)

        Once: approve this exact invocation only.
        \(operationScope)
        Your local selection determines how long the permission lasts.
        """
        // Make the least-privileged approval the highlighted default.
        alert.addButton(withTitle: "Once")
        alert.addButton(withTitle: reusableLabel.map { "Allow \($0) for this session" } ?? "For this session")
        alert.addButton(withTitle: reusableLabel.map { "Always allow \($0)" } ?? "Always allow")
        alert.addButton(withTitle: "Deny")
        let response = alert.runModal()
        let duration: String
        switch response {
        case .alertFirstButtonReturn:
            duration = "once"
        case .alertSecondButtonReturn:
            duration = "session"
        case .alertThirdButtonReturn:
            duration = "persistent"
        default:
            duration = "deny"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "decide-request", requestID, duration]
        setApprovalWorkingDirectory(process, executable: python)
        try? process.run()
        process.waitUntilExit()
        visibleApprovalID = nil
    }

    private func presentApproval(requestID: String, clientName: String, python: String) {
        ApprovalSound.playIfEnabled()
        visibleApprovalID = requestID
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.messageText = "Approve \(clientName) connection?"
        alert.informativeText = "\(clientName) is requesting access to RelayOS. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        setApprovalWorkingDirectory(process, executable: python)
        try? process.run(); process.waitUntilExit()
        visibleApprovalID = nil
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
