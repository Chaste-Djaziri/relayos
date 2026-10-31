// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSViews.swift
import SwiftUI
import AppKit

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\ .openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "computermouse.fill").font(.title2).foregroundStyle(.blue).frame(width: 24, height: 24); VStack(alignment: .leading) { Text("RelayOS").font(.headline); Text(model.running ? "Running locally" : "Server stopped").font(.caption).foregroundStyle(.secondary) }; Spacer() }
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
            Toggle("Emergency stop", isOn: Binding(get: { model.emergencyStop }, set: { model.setEmergencyStop($0) })).tint(.red)
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
            Image(systemName: "computermouse.fill").font(.system(size: 56)).foregroundStyle(.blue).frame(width: 72, height: 72)
            Text("Set up RelayOS").font(.largeTitle.bold())
            Text("Create a private HTTPS MCP endpoint for ChatGPT, Claude, Gemini, and other MCP clients.").foregroundStyle(.secondary)
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
    @AppStorage(ApprovalSound.preferenceKey) private var approvalSoundsEnabled = true
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Label("General", systemImage: "gearshape").tag(SettingsTab.general)
                Label("MCP connections", systemImage: "link").tag(SettingsTab.connections)
                Label("Tools & permissions", systemImage: "square.grid.2x2").tag(SettingsTab.tools)
                Label("Command permissions", systemImage: "terminal.fill").tag(SettingsTab.commandPermissions)
                Label("ngrok", systemImage: "globe").tag(SettingsTab.ngrok)
                Label("Security", systemImage: "lock").tag(SettingsTab.security)
                Label("Activity", systemImage: "clock.arrow.circlepath").tag(SettingsTab.activity)
            }.listStyle(.sidebar)
        } detail: {
            Form {
                switch selected {
                case .general:
                    Section("General") { LabeledContent("MCP endpoint", value: model.endpoint); LabeledContent("Local server", value: model.running ? "Running" : "Stopped"); Button("Restart services") { model.restartServices() } }
                    Section("Approval notifications") { Toggle("Play sound for new approval requests", isOn: $approvalSoundsEnabled); Text("A short sound plays once when a new command or connection approval appears.").font(.caption).foregroundStyle(.secondary) }
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
                    Section("Saved command approvals") { CommandPermissionsView(model: model) }
                    Section("Permissions") { LabeledContent("Screen recording", value: "Managed by macOS"); Button("Open Privacy & Security") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                case .commandPermissions:
                    CommandPermissionsView(model: model)
                case .ngrok:
                    Section("ngrok transport") { LabeledContent("Status", value: model.tunnelRunning ? "Connected" : "Stopped"); LabeledContent("Endpoint", value: model.endpoint); Button("Reconnect") { model.restartServices() } }
                case .security:
                    Section("Security") { Toggle("Emergency stop", isOn: Binding(get: { model.emergencyStop }, set: { model.setEmergencyStop($0) })).tint(.red); Text("Emergency stop blocks active sessions and revokes active OAuth access.").font(.caption).foregroundStyle(.secondary) }
                case .activity:
                    Section("Activity") { Text("Connection and tool activity is kept as local metadata only.").foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).padding()
        }
    }
}

enum SettingsTab: Hashable { case general, connections, tools, commandPermissions, ngrok, security, activity }
