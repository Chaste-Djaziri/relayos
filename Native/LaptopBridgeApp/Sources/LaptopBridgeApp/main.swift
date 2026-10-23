import SwiftUI
import AppKit
import Security

final class RelayOSApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct LaptopBridgeApp: App {
    @StateObject private var model = BridgeModel()
    @NSApplicationDelegateAdaptor(RelayOSApplicationDelegate.self) private var appDelegate

    init() {
        // Use a native macOS glyph for both surfaces. Status-item images are
        // rendered as template masks, so bitmap logos can disappear against
        // the menu bar; the system mouse glyph remains visible in every theme.
        if let image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "RelayOS") {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        Window("RelayOS", id: "main") {
            DesktopWindowView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        MenuBarExtra {
            QuickPanel(model: model)
                .frame(width: 360)
        } label: {
            Image(systemName: "computermouse.fill")
                .frame(width: 18, height: 18)
                .accessibilityLabel("RelayOS")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var running = false
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
    private var server: Process?
    private var tunnel: Process?
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
            Task { @MainActor in self?.shutdownServices() }
        }
        startServices()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkOAuthApprovalsInBackground() }
        timer.resume()
        approvalTimer = timer
        refreshConnectedClients()
        refreshPermissionGrants()
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func shutdownServices() {
        approvalTimer?.cancel()
        approvalTimer = nil
        tunnel?.terminate()
        server?.terminate()
        tunnel = nil
        server = nil
        running = false
        tunnelRunning = false
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

    func startServices() {
        guard server == nil else { return }
        let process = Process()
        let bundledHelper = Bundle.main.resourceURL?
            .appendingPathComponent("Runtime/RelayOSMCPServer")
            .path
        let candidates = [
            bundledHelper,
            FileManager.default.currentDirectoryPath + "/.venv/bin/python",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python",
            "/usr/bin/python3",
        ].compactMap { $0 }
        let executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let isBundledHelper = bundledHelper == executable
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = isBundledHelper ? [] : ["-m", "laptop_bridge.server"]
        // The packaged app is launched from Finder/menu bar, so its current
        // directory is not the repository. Set it explicitly so Python can
        // resolve the laptop_bridge package and its resources.
        if !isBundledHelper {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/GitHub/laptop-bridge")
        }
        var environment = ProcessInfo.processInfo.environment
        // Keep the current public Python OAuth/MCP listener reachable while
        // the Swift edge proxy is introduced incrementally.
        environment["LAPTOP_BRIDGE_MCP_PORT"] = "8765"
        process.environment = environment
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.running = false; self?.server = nil } }
        try? process.run()
        server = process
        running = process.isRunning
        startTunnelIfConfigured()
    }

    func restartServices() {
        server?.terminate(); tunnel?.terminate(); server = nil; tunnel = nil
        running = false; tunnelRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startServices() }
    }

    func restartPythonServer() {
        server?.terminate(); server = nil; running = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.startServices() }
    }

    func startTunnelIfConfigured() {
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
            Task { @MainActor in self?.adoptNgrokEndpoint(url) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.tunnelRunning = false; self?.tunnel = nil } }
        try? process.run(); tunnel = process; tunnelRunning = process.isRunning
        // The agent may emit no stdout when launched from a GUI. Ask its
        // local inspector API for the assigned free hostname as a fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshNgrokEndpoint() }
    }

    private func refreshNgrokEndpoint() {
        guard tunnelRunning, let url = URL(string: "http://127.0.0.1:4040/api/tunnels") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tunnels = object["tunnels"] as? [[String: Any]], let publicURL = tunnels.compactMap({ $0["public_url"] as? String }).first else { return }
            Task { @MainActor in self?.adoptNgrokEndpoint(publicURL) }
        }.resume()
    }

    private func ngrokDomain() -> String? {
        guard let data = try? Data(contentsOf: configURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ngrok = json["ngrok"] as? [String: Any], let domain = ngrok["domain"] as? String, !domain.isEmpty else { return nil }
        return domain
    }

    private func adoptNgrokEndpoint(_ origin: String) {
        let clean = origin.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        endpoint = clean + "/mcp"
        guard let data = try? Data(contentsOf: configURL), var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["public_base_url"] = clean
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? output.write(to: configURL, options: .atomic) }
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
    func setEmergencyStop(_ value: Bool) { emergencyStop = value }

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
            Task { @MainActor in
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
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-oauth"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
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
        alert.messageText = "Approve MCP connection?"
        alert.informativeText = "An MCP client is requesting access to RelayOS. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let decisionProcess = Process(); decisionProcess.executableURL = URL(fileURLWithPath: python)
        decisionProcess.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        decisionProcess.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
        try? decisionProcess.run(); decisionProcess.waitUntilExit()
        visibleApprovalID = nil
    }

    nonisolated private func refreshConnectedClients() {
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-grants"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
            process.standardOutput = pipe
            try? process.run(); process.waitUntilExit()
            guard let data = try? pipe.fileHandleForReading.readToEnd(),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let names = items.compactMap { $0["client_name"] as? String }
            DispatchQueue.main.async { self?.connectedClients = names }
        }
    }

    nonisolated private func refreshPermissionGrants() {
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-permissions"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
            process.standardOutput = pipe; try? process.run(); process.waitUntilExit()
            guard let data = try? pipe.fileHandleForReading.readToEnd(), let grants = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            DispatchQueue.main.async { self?.permissionGrants = grants }
        }
    }

    func revokePermission(_ id: String) {
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        let process = Process(); process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-m", "laptop_bridge.approvals", "revoke-permission", id]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
        try? process.run(); process.waitUntilExit(); refreshPermissionGrants()
    }

    nonisolated func checkOAuthApprovalsInBackground() {
        refreshConnectedClients()
        refreshPermissionGrants()
        checkPendingPermissionRequests()
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-oauth"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
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
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-pending-json"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
        process.standardOutput = pipe; try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let item = items.first, let id = item["request_id"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibleApprovalID == nil, self.handledApprovalIDs[id] == nil else { return }
            self.handledApprovalIDs[id] = Date(); self.presentPermission(requestID: id, item: item, python: python)
        }
    }

    private func presentPermission(requestID: String, item: [String: Any], python: String) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.window.level = .floating; alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let kind = item["kind"] as? String ?? "operation"; let target = item["target"] as? String ?? "requested resource"
        alert.messageText = "Approve \(kind)?"; alert.informativeText = "The MCP client requests access to \(target). Choose how long this permission should remain active."
        alert.addButton(withTitle: "Always allow"); alert.addButton(withTitle: "For this session"); alert.addButton(withTitle: "Once"); alert.addButton(withTitle: "Deny")
        let response = alert.runModal(); let duration = response == .alertFirstButtonReturn ? "persistent" : response == .alertSecondButtonReturn ? "session" : response == .alertThirdButtonReturn ? "once" : nil
        if let duration { let process = Process(); process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-m", "laptop_bridge.approvals", "decide-request", requestID, duration]; process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge"); try? process.run(); process.waitUntilExit() } else { let process = Process(); process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-m", "laptop_bridge.approvals", "decide-request", requestID, "once"]; process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge"); try? process.run(); process.waitUntilExit() }
        visibleApprovalID = nil
    }

    private func presentApproval(requestID: String, clientName: String, python: String) {
        visibleApprovalID = requestID
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.messageText = "Approve (clientName) connection?"
        alert.informativeText = "\(clientName) is requesting access to RelayOS. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/laptop-bridge")
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

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\ .openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image("relayos-black", bundle: .module).resizable().scaledToFit().frame(width: 24, height: 24); VStack(alignment: .leading) { Text("RelayOS").font(.headline); Text(model.running ? "Running locally" : "Server stopped").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            if model.endpoint == "Not configured" {
                GroupBox("First-run setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create your public MCP endpoint with ngrok.").font(.subheadline)
                        HStack {
                            SecureField("ngrok authtoken", text: $model.ngrokToken).textFieldStyle(.roundedBorder)
                            Button("Paste token") { if let value = NSPasteboard.general.string(forType: .string) { model.ngrokToken = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        }
                        TextField("Reserved domain (example.ngrok.app)", text: $model.ngrokDomainValue).textFieldStyle(.roundedBorder)
                        HStack { Button("Install ngrok with Homebrew") { model.installNgrok() }; Button("Save and connect") { model.configureNgrok() }.buttonStyle(.borderedProminent) }
                    }
                }
            }
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.connectedClients.isEmpty {
                        Text("No connected AI clients").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.connectedClients.enumerated()), id: \.offset) { _, name in
                            ConnectionRow(name: name, connected: true)
                        }
                    }
                    Button("Copy MCP endpoint") { model.copyEndpoint() }
                }
            }
            Text(model.endpoint).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red)
            HStack {
                Button("Open RelayOS") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(.bordered)
                Button("Settings") { openWindow(id: "main") }.buttonStyle(.bordered)
                Spacer()
                Button("Restart") { model.restartServices() }.buttonStyle(.bordered)
                Button("Quit RelayOS") { model.shutdownServices(); NSApp.terminate(nil) }.buttonStyle(.bordered)
            }
        }.padding(18)
    }
}

struct DesktopWindowView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        Group {
            if model.endpoint == "Not configured" {
                FreshSetupView(model: model)
            } else {
                SettingsView(model: model)
            }
        }
    }
}

struct FreshSetupView: View {
    @ObservedObject var model: BridgeModel
    @State private var tokenInput = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image("relayos-black", bundle: .module).resizable().scaledToFit().frame(width: 72, height: 72)
            Text("Set up RelayOS").font(.largeTitle.bold())
            Text("Create a private HTTPS MCP endpoint for ChatGPT, Gemini, and other MCP clients.").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Get authtoken", destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
            }.font(.callout)
            Text("1. Install ngrok. 2. Sign in to ngrok and copy your authtoken. ngrok assigns a free stable dev domain automatically.").font(.caption).foregroundStyle(.secondary)
            Form {
                Section("ngrok connection") {
                    HStack {
                            SecureField("ngrok authtoken", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 30)
                        Button("Paste token") {
                            if let value = NSPasteboard.general.string(forType: .string) { tokenInput = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    }
                    Text("Your free ngrok dev domain will appear automatically after connection. The token is stored locally.").font(.caption).foregroundStyle(.secondary)
                    if model.ngrokInstallState == "Installing ngrok…" { ProgressView("Installing ngrok…") }
                    else if !model.ngrokInstallState.isEmpty { Text(model.ngrokInstallState).font(.caption).foregroundStyle(model.ngrokInstallState.contains("successfully") || model.ngrokInstallState.contains("already") ? .green : .red) }
                }
                Section {
                    HStack {
                        Button("Install ngrok with Homebrew") { model.installNgrok() }
                        Spacer()
                        Button("Save and connect") { model.ngrokToken = tokenInput; model.ngrokDomainValue = ""; model.configureNgrok() }.buttonStyle(.borderedProminent)
                    }
                }
            }.formStyle(.grouped)
            Spacer()
        }.padding(36)
    }
}

struct ConnectionRow: View {
    let name: String; let connected: Bool
    var body: some View { HStack { Text(name); Spacer(); Text(connected ? "Connected" : "OAuth ready").font(.caption).foregroundStyle(connected ? .green : .secondary) } }
}

struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var selected: SettingsTab = .general
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Label("General", systemImage: "gearshape").tag(SettingsTab.general)
                Label("MCP connections", systemImage: "link").tag(SettingsTab.connections)
                Label("Tools & permissions", systemImage: "square.grid.2x2").tag(SettingsTab.tools)
                Label("ngrok", systemImage: "globe").tag(SettingsTab.ngrok)
                Label("Security", systemImage: "lock").tag(SettingsTab.security)
                Label("Activity", systemImage: "clock.arrow.circlepath").tag(SettingsTab.activity)
            }.listStyle(.sidebar)
        } detail: {
            Form {
                switch selected {
                case .general:
                    Section("General") { LabeledContent("MCP endpoint", value: model.endpoint); LabeledContent("Local server", value: model.running ? "Running" : "Stopped"); Button("Restart services") { model.restartServices() } }
                case .connections:
                    Section("Connected AI clients") {
                        if model.connectedClients.isEmpty { Text("No connected AI clients").foregroundStyle(.secondary) }
                        ForEach(Array(model.connectedClients.enumerated()), id: \.offset) { _, name in LabeledContent(name, value: "Connected").foregroundStyle(.green) }
                        Button("Copy MCP endpoint") { model.copyEndpoint() }
                    }
                case .tools:
                    Section("Available tools") { Toggle("Project tools", isOn: $model.projectTools); Button("Save tool settings") { model.saveCapabilities() } }
                    Section("Persistent permissions") {
                        if model.permissionGrants.isEmpty { Text("No persistent folder permissions yet.").foregroundStyle(.secondary) }
                        ForEach(Array(model.permissionGrants.enumerated()), id: \.offset) { _, grant in
                            HStack {
                                VStack(alignment: .leading) { Text((grant["grant_type"] as? String ?? "permission").capitalized); Text(grant["scope"] as? String ?? "").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Revoke") { if let id = grant["token"] as? String { model.revokePermission(id) } }
                            }
                        }
                        Button("Revoke all permissions", role: .destructive) { for grant in model.permissionGrants { if let id = grant["token"] as? String { model.revokePermission(id) } } }
                    }
                    Section("Permissions") { LabeledContent("Screen recording", value: "Managed by macOS"); Button("Open Privacy & Security") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                case .ngrok:
                    Section("ngrok transport") { LabeledContent("Status", value: model.tunnelRunning ? "Connected" : "Stopped"); LabeledContent("Endpoint", value: model.endpoint); Button("Reconnect") { model.restartServices() } }
                case .security:
                    Section("Security") { Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red); Text("Emergency stop blocks active sessions and revokes active OAuth access.").font(.caption).foregroundStyle(.secondary) }
                case .activity:
                    Section("Activity") { Text("Connection and tool activity is kept as local metadata only.").foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).padding()
        }
    }
}

enum SettingsTab: Hashable { case general, connections, tools, ngrok, security, activity }
