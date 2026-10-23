import SwiftUI
import AppKit
import Security

@main
struct LaptopBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
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

    private let configURL: URL
    private var server: Process?
    private var tunnel: Process?
    private var approvalTimer: Timer?
    private var visibleApprovalID: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".laptop-bridge/config.json")
        loadConfig()
        startServices()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkOAuthApprovals() }
        }
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
        let executable = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        if let token = Keychain.read(account: "cloudflare_tunnel_token") {
            process.arguments = ["tunnel", "run", "--token", token]
        } else {
            let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared/config.yml").path
            guard FileManager.default.fileExists(atPath: config) else { return }
            process.arguments = ["--config", config, "tunnel", "run"]
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.tunnelRunning = false; self?.tunnel = nil } }
        try? process.run(); tunnel = process; tunnelRunning = process.isRunning
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
        alert.messageText = "Approve Gemini connection?"
        alert.informativeText = "A Gemini client is requesting access to Laptop Bridge. Approve only if you initiated this connection."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        let decision = alert.runModal() == .alertFirstButtonReturn ? "approve" : "deny"
        let decisionProcess = Process(); decisionProcess.executableURL = URL(fileURLWithPath: python)
        decisionProcess.arguments = ["-m", "laptop_bridge.approvals", "decide-oauth", requestID, decision]
        try? decisionProcess.run(); decisionProcess.waitUntilExit()
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
}

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "link.circle.fill").foregroundStyle(.blue).font(.title2); VStack(alignment: .leading) { Text("Laptop Bridge").font(.headline); Text(model.running ? "Running locally" : "Server stopped").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionRow(name: "ChatGPT", connected: model.chatGPTConnected)
                    ConnectionRow(name: "Gemini", connected: model.geminiConnected)
                    Button("Copy MCP endpoint") { model.copyEndpoint() }
                }
            }
            Text(model.endpoint).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red)
            HStack { SettingsLink { Text("Settings") }.buttonStyle(.bordered); Spacer(); Button("Restart") { model.restartServices() }.buttonStyle(.bordered) }
        }.padding(18)
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
            List { Label("General", systemImage: "gearshape"); Label("Connections", systemImage: "link"); Label("Features", systemImage: "square.grid.2x2"); Label("Cloudflare", systemImage: "globe"); Label("Security", systemImage: "lock"); Label("Activity", systemImage: "clock.arrow.circlepath") }.listStyle(.sidebar)
        } detail: {
            Form {
                Section("General") { LabeledContent("MCP endpoint", value: model.endpoint); LabeledContent("Local server", value: model.running ? "Running" : "Stopped"); Button("Restart services") { model.restartServices() } }
                Section("Connections") { LabeledContent("ChatGPT", value: model.chatGPTConnected ? "Connected" : "OAuth ready"); LabeledContent("Gemini", value: model.geminiConnected ? "Connected" : "OAuth ready"); Button("Copy MCP endpoint") { model.copyEndpoint() } }
                Section("Features") { Toggle("Screen guidance", isOn: $model.screenGuidance); Toggle("Project tools", isOn: $model.projectTools); Button("Save feature settings") { model.saveCapabilities() } }
                Section("Security") { Toggle("Emergency stop", isOn: $model.emergencyStop).tint(.red); Text("Emergency stop blocks active sessions and revokes active OAuth access.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).padding()
        }
    }
}
