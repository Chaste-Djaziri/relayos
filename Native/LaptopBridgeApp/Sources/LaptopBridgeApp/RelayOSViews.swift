// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSViews.swift
import SwiftUI
import AppKit

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\ .openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "computermouse.fill").font(.title2).foregroundStyle(.blue).frame(width: 24, height: 24); VStack(alignment: .leading) { Text("RelayOS").font(.headline); Text(model.running ? "MCP healthy" : "MCP offline or restarting").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            LabeledContent("Public tunnel", value: model.tunnelHealth.label)
                .font(.caption)
            if !model.serviceNotice.isEmpty {
                Label(model.serviceNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
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
            if !model.approvalInbox.isEmpty {
                Button("Review \(model.approvalInbox.count) pending approvals") {
                    model.showApprovalCenter()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(.borderedProminent)
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

struct ConnectionRow: View {
    let name: String
    let connected: Bool
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(connected ? "Connected" : "OAuth ready")
                .font(.caption)
                .foregroundStyle(connected ? .green : .secondary)
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
        .background(CustomWindowAccessor())
    }
}

struct CustomWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1.0)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}

struct CustomTrafficLightsAndNav: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSApp.keyWindow?.close() ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.close()
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.38, blue: 0.35))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.88, green: 0.20, blue: 0.18), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.05, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)

            Button {
                NSApp.keyWindow?.miniaturize(nil) ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.miniaturize(nil)
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.22))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.87, green: 0.60, blue: 0.10), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.30, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)

            Button {
                NSApp.keyWindow?.zoom(nil) ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.zoom(nil)
            } label: {
                Circle()
                    .fill(Color(red: 0.16, green: 0.78, blue: 0.30))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.12, green: 0.65, blue: 0.20), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.05, green: 0.35, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)

            Spacer().frame(width: 6)

            HStack(spacing: 10) {
                Button {} label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.45))
                }
                .buttonStyle(.plain)

                Button {} label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.28))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { isHovering = $0 }
    }
}

struct IconRailView: View {
    @State private var hoveredIndex: Int? = nil

    private let topIcons: [(String, String)] = [
        ("house", "Home"),
        ("magnifyingglass", "Search"),
        ("bubble.left.and.bubble.right", "Chats"),
        ("clock", "History"),
        ("books.vertical", "Library"),
        ("ellipsis", "More"),
    ]

    private let bottomIcons: [(String, String)] = [
        ("point.topleft.down.curvedto.point.bottomright.up", "Workflows"),
        ("square.grid.2x2", "Apps"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 52)

            ForEach(0..<topIcons.count, id: \.self) { idx in
                Button {} label: {
                    Image(systemName: topIcons[idx].0)
                        .font(.system(size: 14))
                        .foregroundStyle(hoveredIndex == idx ? .white : Color(white: 0.55))
                        .frame(width: 34, height: 34)
                        .background(hoveredIndex == idx ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { hoveredIndex = $0 ? idx : nil }
                .padding(.vertical, 2)
            }

            Rectangle()
                .fill(Color(white: 0.16))
                .frame(width: 22, height: 1)
                .padding(.vertical, 10)

            ForEach(0..<bottomIcons.count, id: \.self) { idx in
                let actualIdx = idx + 10
                Button {} label: {
                    Image(systemName: bottomIcons[idx].0)
                        .font(.system(size: 14))
                        .foregroundStyle(hoveredIndex == actualIdx ? .white : Color(white: 0.55))
                        .frame(width: 34, height: 34)
                        .background(hoveredIndex == actualIdx ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { hoveredIndex = $0 ? actualIdx : nil }
                .padding(.vertical, 2)
            }

            Spacer()

            Button {} label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.22))
                        .frame(width: 26, height: 26)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(white: 0.85))
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .frame(width: 48)
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
    }
}

struct SidebarItemModel: Identifiable {
    var id: SettingsTab { tab }
    let tab: SettingsTab
    let title: String
    let icon: String
    var isExternal: Bool = false
}

struct SidebarItemRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badgeCount: Int = 0
    var isExternalLink: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? .white : (isHovered ? Color(white: 0.95) : Color(white: 0.55)))

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : (isHovered ? .white : Color(white: 0.82)))
                    .lineLimit(1)

                Spacer()

                if isExternalLink {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.4))
                }

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(white: 0.20) : (isHovered ? Color(white: 0.12) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct CustomSidebarView: View {
    @ObservedObject var model: BridgeModel
    @Binding var selected: SettingsTab
    @Binding var searchText: String

    private let personalItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .general, title: "General", icon: "gearshape"),
        SidebarItemModel(tab: .notifications, title: "Notifications", icon: "bell"),
        SidebarItemModel(tab: .importData, title: "Import", icon: "tray.and.arrow.down"),
        SidebarItemModel(tab: .profile, title: "Profile", icon: "person.crop.circle", isExternal: true),
        SidebarItemModel(tab: .appearance, title: "Appearance", icon: "paintpalette"),
        SidebarItemModel(tab: .account, title: "Account", icon: "person.badge.shield.checkmark"),
        SidebarItemModel(tab: .archivedChats, title: "Archived chats", icon: "archivebox"),
        SidebarItemModel(tab: .parentalControls, title: "Parental controls", icon: "figure.2.and.child.holdinghands"),
        SidebarItemModel(tab: .trustedContact, title: "Trusted contact", icon: "heart.text.square"),
        SidebarItemModel(tab: .voice, title: "Voice", icon: "mic"),
        SidebarItemModel(tab: .storage, title: "Storage", icon: "internaldrive"),
        SidebarItemModel(tab: .configuration, title: "Configuration", icon: "slider.horizontal.3"),
        SidebarItemModel(tab: .personalization, title: "Personalization", icon: "wand.and.stars"),
        SidebarItemModel(tab: .miniAndPets, title: "Mini & Pets", icon: "face.smiling"),
        SidebarItemModel(tab: .keyboardShortcuts, title: "Keyboard shortcuts", icon: "keyboard"),
        SidebarItemModel(tab: .usageAndBilling, title: "Usage & billing", icon: "creditcard"),
        SidebarItemModel(tab: .dataControls, title: "Data controls", icon: "circle.dashed"),
    ]

    private let integrationItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .plugins, title: "@ Plugins", icon: "at"),
        SidebarItemModel(tab: .passwords, title: "Passwords", icon: "key"),
        SidebarItemModel(tab: .computerUse, title: "Computer use", icon: "cursorarrow.rays"),
        SidebarItemModel(tab: .appshots, title: "Appshots", icon: "camera"),
        SidebarItemModel(tab: .browser, title: "Browser", icon: "globe"),
        SidebarItemModel(tab: .cloudComputer, title: "Cloud computer", icon: "server.rack"),
        SidebarItemModel(tab: .approvals, title: "Approvals", icon: "tray.full"),
        SidebarItemModel(tab: .activity, title: "Activity", icon: "clock.arrow.circlepath"),
        SidebarItemModel(tab: .tools, title: "Tools & permissions", icon: "square.grid.2x2"),
    ]

    private let codingItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .hooks, title: "Hooks", icon: "arrow.triangle.branch"),
        SidebarItemModel(tab: .connections, title: "Connections", icon: "network"),
        SidebarItemModel(tab: .commandPermissions, title: "Command permissions", icon: "terminal.fill"),
        SidebarItemModel(tab: .terminalJobs, title: "Terminal jobs", icon: "terminal"),
        SidebarItemModel(tab: .ngrok, title: "ngrok", icon: "globe.americas.fill"),
        SidebarItemModel(tab: .security, title: "Security", icon: "lock.shield"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CustomTrafficLightsAndNav()
                .padding(.top, 14)
                .padding(.leading, 16)
                .padding(.bottom, 12)

            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    let filteredPersonal = personalItems.filter { matchesSearch($0.title) }
                    if !filteredPersonal.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personal")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 12)
                                .padding(.bottom, 2)

                            ForEach(filteredPersonal) { item in
                                SidebarItemRow(
                                    title: item.title,
                                    systemImage: item.icon,
                                    isSelected: selected == item.tab,
                                    isExternalLink: item.isExternal
                                ) {
                                    selected = item.tab
                                }
                            }
                        }
                    }

                    let filteredIntegration = integrationItems.filter { matchesSearch($0.title) }
                    if !filteredIntegration.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Integrations")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 12)
                                .padding(.bottom, 2)

                            ForEach(filteredIntegration) { item in
                                SidebarItemRow(
                                    title: item.title,
                                    systemImage: item.icon,
                                    isSelected: selected == item.tab,
                                    badgeCount: item.tab == .approvals ? model.approvalInbox.count : 0
                                ) {
                                    selected = item.tab
                                }
                            }
                        }
                    }

                    let filteredCoding = codingItems.filter { matchesSearch($0.title) }
                    if !filteredCoding.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coding")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 12)
                                .padding(.bottom, 2)

                            ForEach(filteredCoding) { item in
                                SidebarItemRow(
                                    title: item.title,
                                    systemImage: item.icon,
                                    isSelected: selected == item.tab
                                ) {
                                    selected = item.tab
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .frame(width: 224)
        .background(Color(red: 0.095, green: 0.095, blue: 0.095))
    }

    private func matchesSearch(_ text: String) -> Bool {
        searchText.isEmpty || text.localizedCaseInsensitiveContains(searchText)
    }
}

struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var selected: SettingsTab = .general
    @State private var searchText: String = ""
    private var pageTitle: String { selected.rawValue }
    @AppStorage(ApprovalSound.preferenceKey) private var approvalSoundsEnabled = true
    @AppStorage(ApprovalArrivalNotification.enabledKey) private var approvalNotificationsEnabled = false

    var body: some View {
        HStack(spacing: 0) {
            IconRailView()

            Rectangle()
                .fill(Color(white: 0.14))
                .frame(width: 1)

            CustomSidebarView(model: model, selected: $selected, searchText: $searchText)

            Rectangle()
                .fill(Color(white: 0.14))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 26)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(pageTitle)
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.7)
                            .foregroundStyle(.white)

                        tabDetailView(selected)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        }
        .background(CustomWindowAccessor())
        .onChange(of: model.approvalNavigationRequest) { _, _ in
            selected = .approvals
        }
    }

    @ViewBuilder
    private func tabDetailView(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .appearance:
                RelayOSAppearanceView()
            case .approvals:
                ApprovalCenterView(model: model)
            case .general:
                Section("Connections") {
                    LabeledContent("MCP endpoint", value: model.endpoint)
                    LabeledContent("Local MCP", value: model.mcpHealth.rawValue.capitalized)
                    LabeledContent("Public MCP", value: model.tunnelHealth.label)
                    if !model.serviceNotice.isEmpty { Text(model.serviceNotice).foregroundStyle(.orange) }
                    Button("Restart services") { model.restartServices() }
                }
                Section("Approval notifications") {
                    Toggle("Play sound for new approval requests", isOn: $approvalSoundsEnabled)
                    Toggle("macOS notifications for new approval requests", isOn: $approvalNotificationsEnabled)
                        .onChange(of: approvalNotificationsEnabled) { _, enabled in
                            if enabled { ApprovalArrivalNotification.requestPermission() }
                        }
                    Text("Alerts are sent once per newly discovered request; command arguments are excluded from notifications.").font(.caption).foregroundStyle(.secondary)
                }
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
                Section("ngrok transport") { LabeledContent("Process", value: model.tunnelRunning ? "Running" : "Stopped"); LabeledContent("Public endpoint", value: model.tunnelHealth.label); LabeledContent("MCP endpoint", value: model.endpoint); Text("Public health is verified by unauthenticated HTTP 401; a running ngrok process alone does not prove connectivity.").font(.caption).foregroundStyle(.secondary); Button("Reconnect") { model.restartServices() } }
            case .security:
                Section("Security") { Toggle("Emergency stop", isOn: Binding(get: { model.emergencyStop }, set: { model.setEmergencyStop($0) })).tint(.red); Text("Emergency stop blocks active sessions and revokes active OAuth access.").font(.caption).foregroundStyle(.secondary) }
            case .activity:
                ApprovalCenterView(model: model)
            case .terminalJobs:
                CommandJobsView(model: model)
            default:
                Section(tab.rawValue) {
                    Text("\(tab.rawValue) settings are configured and synchronized with your client.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

enum SettingsTab: String, Hashable, CaseIterable {
    case general = "General"
    case notifications = "Notifications"
    case importData = "Import"
    case profile = "Profile"
    case appearance = "Appearance"
    case account = "Account"
    case archivedChats = "Archived chats"
    case parentalControls = "Parental controls"
    case trustedContact = "Trusted contact"
    case voice = "Voice"
    case storage = "Storage"
    case configuration = "Configuration"
    case personalization = "Personalization"
    case miniAndPets = "Mini & Pets"
    case keyboardShortcuts = "Keyboard shortcuts"
    case usageAndBilling = "Usage & billing"
    case dataControls = "Data controls"

    case plugins = "@ Plugins"
    case passwords = "Passwords"
    case computerUse = "Computer use"
    case appshots = "Appshots"
    case browser = "Browser"
    case cloudComputer = "Cloud computer"
    case approvals = "Approvals"
    case activity = "Activity"
    case tools = "Tools & permissions"

    case hooks = "Hooks"
    case connections = "Connections"
    case commandPermissions = "Command permissions"
    case terminalJobs = "Terminal jobs"
    case ngrok = "ngrok"
    case security = "Security"
}
