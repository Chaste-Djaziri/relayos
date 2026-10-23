import SwiftUI
import AppKit
import Security

@main
struct LaptopBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        Window("Laptop Bridge", id: "main") {
            DesktopWindowView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        MenuBarExtra("Laptop Bridge", systemImage: "link.circle.fill") {
            QuickPanel(model: model)
                .frame(width: 360)
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

    private let configURL: URL
    private var server: Process?
    private var tunnel: Process?
    private var approvalTimer: DispatchSourceTimer?
    private var visibleApprovalID: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".laptop-bridge/config.json")
        loadConfig()
        startServices()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkOAuthApprovalsInBackground() }
        timer.resume()
        approvalTimer = timer
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let base = json["public_base_url"] as? String, !base.isEmpty { endpoint = base + "/mcp" }
        if let caps = json["capabilities"] as? [String: Any] {
            screenGuidance = caps["screen_guidance"] as? Bool ?? false
            projectTools = caps["project_tools"] as? Bool ?? false
        }
    }

    func startServices() {
        guard server == nil else { return }
        let process = Process()
        let candidates = [
            FileManager.default.currentDirectoryPath + "/.venv/bin/python",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python",
            "/usr/bin/python3",
        ]
        let python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.server"]
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

    func startTunnelIfConfigured() {
        guard let token = Keychain.read(account: "ngrok_authtoken"), let domain = ngrokDomain() else { return }
        let executable = ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["http", "127.0.0.1:8765", "--domain", domain]
        var environment = ProcessInfo.processInfo.environment
        environment["NGROK_AUTHTOKEN"] = token
        process.environment = environment
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.tunnelRunning = false; self?.tunnel = nil } }
        try? process.run(); tunnel = process; tunnelRunning = process.isRunning
    }

    private func ngrokDomain() -> String? {
        guard let data = try? Data(contentsOf: configURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ngrok = json["ngrok"] as? [String: Any], let domain = ngrok["domain"] as? String, !domain.isEmpty else { return nil }
        return domain
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
        guard !ngrokToken.isEmpty, domain.contains("."), !domain.contains("/") else { return }
        Keychain.write(account: "ngrok_authtoken", value: ngrokToken)
        var json = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: configURL)) ?? Data())) as? [String: Any] ?? [:]
        json["public_base_url"] = "https://\(domain)"
        json["active_transport"] = "ngrok"
        json["setup_complete"] = true
        json["ngrok"] = ["enabled": true, "domain": domain, "region": "", "config_path": "", "agent_version": ""]
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: configURL, options: .atomic) }
        endpoint = "https://\(domain)/mcp"
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
        alert.informativeText = "An MCP client is requesting access to Laptop Bridge. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let decisionProcess = Process(); decisionProcess.executableURL = URL(fileURLWithPath: python)
        decisionProcess.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        try? decisionProcess.run(); decisionProcess.waitUntilExit()
        visibleApprovalID = nil
    }

    nonisolated func checkOAuthApprovalsInBackground() {
        let python = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/GitHub/laptop-bridge/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "list-oauth"]
        process.standardOutput = pipe
        try? process.run(); process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = items.first,
              let requestID = item["request_id"] as? String else { return }
        Task { @MainActor [weak self] in
            guard let self, self.visibleApprovalID == nil else { return }
            self.presentApproval(requestID: requestID, python: python)
        }
    }

    private func presentApproval(requestID: String, python: String) {
        visibleApprovalID = requestID
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.level = .floating
        alert.messageText = "Approve MCP connection?"
        alert.informativeText = "An MCP client is requesting access to Laptop Bridge. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
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

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\ .openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "link.circle.fill").foregroundStyle(.blue).font(.title2); VStack(alignment: .leading) { Text("Laptop Bridge").font(.headline); Text(model.running ? "Running locally" : "Server stopped").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            if model.endpoint == "Not configured" {
                GroupBox("First-run setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create your public MCP endpoint with ngrok.").font(.subheadline)
                        SecureField("ngrok authtoken", text: $model.ngrokToken)
                        TextField("Reserved domain (example.ngrok.app)", text: $model.ngrokDomainValue)
                        HStack { Button("Install ngrok with Homebrew") { model.installNgrok() }; Button("Save and connect") { model.configureNgrok() }.buttonStyle(.borderedProminent) }
                    }
                }
            }
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionRow(name: "ChatGPT", connected: model.chatGPTConnected)
                    ConnectionRow(name: "MCP client", connected: model.geminiConnected)
                    Button("Copy MCP endpoint") { model.copyEndpoint() }
                }
            }
            Text(model.endpoint).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red)
            HStack { Button("Settings") { openWindow(id: "main") }.buttonStyle(.bordered); Spacer(); Button("Restart") { model.restartServices() }.buttonStyle(.bordered) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "link.circle.fill").font(.system(size: 42)).foregroundStyle(.blue)
            Text("Set up Laptop Bridge").font(.largeTitle.bold())
            Text("Create a private HTTPS MCP endpoint for ChatGPT, Gemini, and other MCP clients.").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Get authtoken", destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
                Link("Reserve a domain", destination: URL(string: "https://dashboard.ngrok.com/domains")!)
            }.font(.callout)
            Form {
                Section("ngrok connection") {
                    SecureField("ngrok authtoken", text: $model.ngrokToken)
                    TextField("Reserved domain (example.ngrok.app)", text: $model.ngrokDomainValue)
                    Text("Reserve a domain in the ngrok dashboard. Your token is stored only in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                    if model.ngrokInstallState == "Installing ngrok…" { ProgressView("Installing ngrok…") }
                    else if !model.ngrokInstallState.isEmpty { Text(model.ngrokInstallState).font(.caption).foregroundStyle(model.ngrokInstallState.contains("successfully") || model.ngrokInstallState.contains("already") ? .green : .red) }
                }
                Section {
                    HStack {
                        Button("Install ngrok with Homebrew") { model.installNgrok() }
                        Spacer()
                        Button("Save and connect") { model.configureNgrok() }.buttonStyle(.borderedProminent)
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
    var body: some View {
        NavigationSplitView {
            List { Label("General", systemImage: "gearshape"); Label("Connections", systemImage: "link"); Label("Features", systemImage: "square.grid.2x2"); Label("ngrok", systemImage: "globe"); Label("Security", systemImage: "lock"); Label("Activity", systemImage: "clock.arrow.circlepath") }.listStyle(.sidebar)
        } detail: {
            Form {
                Section("General") { LabeledContent("MCP endpoint", value: model.endpoint); LabeledContent("Local server", value: model.running ? "Running" : "Stopped"); Button("Restart services") { model.restartServices() } }
                Section("Connections") { LabeledContent("ChatGPT", value: model.chatGPTConnected ? "Connected" : "OAuth ready"); LabeledContent("MCP client", value: model.geminiConnected ? "Connected" : "OAuth ready"); Button("Copy MCP endpoint") { model.copyEndpoint() } }
                Section("Features") { Toggle("Screen guidance", isOn: $model.screenGuidance); Toggle("Project tools", isOn: $model.projectTools); Button("Save feature settings") { model.saveCapabilities() } }
                Section("Security") { Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red); Text("Emergency stop blocks active sessions and revokes active OAuth access.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).padding()
        }
    }
}
