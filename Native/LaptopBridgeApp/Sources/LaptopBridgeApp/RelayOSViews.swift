// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSViews.swift
import SwiftUI
import AppKit

// MARK: - Menu Bar Quick Panel

struct QuickPanel: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "computermouse.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading) {
                    Text("RelayOS").font(.headline)
                    Text(model.running ? "MCP healthy" : "MCP offline or restarting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LabeledContent("Public tunnel", value: model.tunnelHealth.label)
                .font(.caption)

            if !model.serviceNotice.isEmpty {
                Label(model.serviceNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.endpoint == "Not configured" {
                GroupBox("First-run setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create your public MCP endpoint with ngrok.").font(.subheadline)
                        HStack {
                            SecureField("ngrok authtoken", text: $model.ngrokToken)
                                .textFieldStyle(.roundedBorder)
                            Button("Paste token") {
                                if let value = NSPasteboard.general.string(forType: .string) {
                                    model.ngrokToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                        }
                        TextField("Reserved domain (example.ngrok.app)", text: $model.ngrokDomainValue)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Install ngrok with Homebrew") { model.installNgrok() }
                            Button("Save and connect") { model.configureNgrok() }
                                .buttonStyle(.borderedProminent)
                        }
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
                }
                .buttonStyle(.borderedProminent)
            }

            Text(model.endpoint)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Toggle("Emergency stop", isOn: Binding(
                get: { model.emergencyStop },
                set: { model.setEmergencyStop($0) }
            ))
            .toggleStyle(.sleekSwitch(tint: Color(red: 0.92, green: 0.26, blue: 0.26)))

            HStack {
                Button("Open RelayOS") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.bordered)

                Button("Settings") {
                    openWindow(id: "main")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Restart") { model.restartServices() }
                    .buttonStyle(.bordered)
                Button("Quit RelayOS") {
                    model.shutdownServices()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
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

// MARK: - First-Run Setup View

struct FreshSetupView: View {
    @ObservedObject var model: BridgeModel
    @State private var tokenInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "computermouse.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
            Text("Set up RelayOS").font(.largeTitle.bold())
            Text("Create a private HTTPS MCP endpoint for ChatGPT, Claude, Gemini, and other MCP clients.")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("Get authtoken", destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
            }
            .font(.callout)

            Text("1. Install ngrok. 2. Sign in to ngrok and copy your authtoken. ngrok assigns a free stable dev domain automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Section("ngrok connection") {
                    HStack {
                        SecureField("ngrok authtoken", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 30)
                        Button("Paste token") {
                            if let value = NSPasteboard.general.string(forType: .string) {
                                tokenInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    Text("Your free ngrok dev domain will appear automatically after connection. The token is stored locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.ngrokInstallState == "Installing ngrok…" {
                        ProgressView("Installing ngrok…")
                    } else if !model.ngrokInstallState.isEmpty {
                        Text(model.ngrokInstallState)
                            .font(.caption)
                            .foregroundStyle(model.ngrokInstallState.contains("successfully") || model.ngrokInstallState.contains("already") ? .green : .red)
                    }
                }

                Section {
                    HStack {
                        Button("Install ngrok with Homebrew") { model.installNgrok() }
                        Spacer()
                        Button("Save and connect") {
                            model.ngrokToken = tokenInput
                            model.ngrokDomainValue = ""
                            model.configureNgrok()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .padding(36)
    }
}

// MARK: - Desktop Window Root

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

// MARK: - Custom Window Accessor (Hides macOS titlebar & standard buttons)

struct CustomWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.095, green: 0.095, blue: 0.095, alpha: 1.0)
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

// MARK: - Custom Traffic Lights and Navigation

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

            HStack(spacing: 8) {
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

// MARK: - Reusable UI Components

enum SettingsButtonStyle {
    case primary
    case secondary
    case destructive
}

struct SettingsButton: View {
    let title: String
    var icon: String? = nil
    var style: SettingsButtonStyle = .secondary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(backgroundView)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            isHovered ? Color.blue.opacity(0.85) : Color.blue
        case .secondary:
            isHovered ? Color(white: 0.25) : Color(white: 0.19)
        case .destructive:
            isHovered ? Color.red.opacity(0.85) : Color(red: 0.72, green: 0.16, blue: 0.16)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color.blue.opacity(0.6)
        case .secondary:
            return isHovered ? Color(white: 0.36) : Color(white: 0.26)
        case .destructive:
            return Color.red.opacity(0.6)
        }
    }
}

struct StatusBadge: View {
    enum StatusType {
        case healthy
        case warning
        case offline
        case neutral
    }

    let text: String
    var status: StatusType = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(dotColor.opacity(0.12), in: Capsule())
    }

    private var dotColor: Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .offline: return .red
        case .neutral: return Color(white: 0.6)
        }
    }

    private var textColor: Color {
        switch status {
        case .healthy: return Color(red: 0.45, green: 0.88, blue: 0.45)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.32)
        case .offline: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .neutral: return Color(white: 0.75)
        }
    }
}

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var tintColor: Color = Color(red: 0.18, green: 0.52, blue: 0.98)
    var offColor: Color = Color(red: 0.24, green: 0.24, blue: 0.26)

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? tintColor : offColor)
                    .frame(width: 40, height: 23)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? tintColor.opacity(0.85) : Color(white: 0.32), lineWidth: 0.8)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 17, height: 17)
                    .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    .frame(maxWidth: 40, alignment: isOn ? .trailing : .leading)
                    .padding(.horizontal, 3)
            }
            .frame(width: 40, height: 23)
        }
        .buttonStyle(.plain)
    }
}

struct SleekSwitchToggleStyle: ToggleStyle {
    var tint: Color = Color(red: 0.18, green: 0.52, blue: 0.98)
    var offColor: Color = Color(red: 0.24, green: 0.24, blue: 0.26)

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                    configuration.isOn.toggle()
                }
            } label: {
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? tint : offColor)
                        .frame(width: 40, height: 23)
                        .overlay(
                            Capsule()
                                .stroke(configuration.isOn ? tint.opacity(0.85) : Color(white: 0.32), lineWidth: 0.8)
                        )

                    Circle()
                        .fill(Color.white)
                        .frame(width: 17, height: 17)
                        .shadow(color: Color.black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                        .frame(maxWidth: 40, alignment: configuration.isOn ? .trailing : .leading)
                        .padding(.horizontal, 3)
                }
                .frame(width: 40, height: 23)
            }
            .buttonStyle(.plain)
        }
    }
}

extension ToggleStyle where Self == SleekSwitchToggleStyle {
    static var sleekSwitch: SleekSwitchToggleStyle { SleekSwitchToggleStyle() }
    static func sleekSwitch(tint: Color) -> SleekSwitchToggleStyle { SleekSwitchToggleStyle(tint: tint) }
}

struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.60))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Color(red: 0.14, green: 0.14, blue: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color(white: 0.19), lineWidth: 1)
            )
        }
    }
}

struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let showDivider: Bool
    let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(white: 0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showDivider {
                Rectangle()
                    .fill(Color(white: 0.18))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Sidebar Item

struct SidebarItemModel: Identifiable {
    var id: SettingsTab { tab }
    let tab: SettingsTab
    let title: String
    let icon: String
}

struct SidebarItemRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badgeCount: Int = 0
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
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(white: 0.20) : (isHovered ? Color(white: 0.12) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Custom Sidebar View (No Icon Rail, Only Functional Tabs)

struct CustomSidebarView: View {
    @ObservedObject var model: BridgeModel
    @Binding var selected: SettingsTab
    @Binding var searchText: String

    private let generalItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .general, title: "General", icon: "gearshape"),
        SidebarItemModel(tab: .appearance, title: "Appearance", icon: "paintpalette"),
        SidebarItemModel(tab: .security, title: "Security", icon: "lock.shield"),
    ]

    private let accessItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .approvals, title: "Approvals", icon: "tray.full"),
        SidebarItemModel(tab: .activity, title: "Activity", icon: "clock.arrow.circlepath"),
        SidebarItemModel(tab: .connections, title: "Connections", icon: "network"),
        SidebarItemModel(tab: .ngrok, title: "ngrok transport", icon: "globe.americas.fill"),
    ]

    private let toolItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .tools, title: "Tools & permissions", icon: "square.grid.2x2"),
        SidebarItemModel(tab: .commandPermissions, title: "Command permissions", icon: "terminal.fill"),
        SidebarItemModel(tab: .terminalJobs, title: "Terminal jobs", icon: "terminal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CustomTrafficLightsAndNav()
                .padding(.top, 8)
                .padding(.leading, 16)
                .padding(.bottom, 10)

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
                    let filteredGeneral = generalItems.filter { matchesSearch($0.title) }
                    if !filteredGeneral.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("General")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 10)
                                .padding(.bottom, 2)

                            ForEach(filteredGeneral) { item in
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

                    let filteredAccess = accessItems.filter { matchesSearch($0.title) }
                    if !filteredAccess.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Integrations & Approvals")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 10)
                                .padding(.bottom, 2)

                            ForEach(filteredAccess) { item in
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

                    let filteredTools = toolItems.filter { matchesSearch($0.title) }
                    if !filteredTools.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Execution & Tools")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.leading, 10)
                                .padding(.bottom, 2)

                            ForEach(filteredTools) { item in
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

// MARK: - Tab Detail Views

private struct GeneralDetailView: View {
    @ObservedObject var model: BridgeModel
    @AppStorage(ApprovalSound.preferenceKey) private var approvalSoundsEnabled = true
    @AppStorage(ApprovalArrivalNotification.enabledKey) private var approvalNotificationsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Connections") {
                SettingsCardRow(
                    title: "MCP endpoint",
                    subtitle: "Public HTTPS URL for AI clients to connect to this machine"
                ) {
                    HStack(spacing: 8) {
                        Text(model.endpoint)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color(white: 0.75))
                            .lineLimit(1)
                        SettingsButton(title: "Copy", icon: "doc.on.doc", style: .secondary) {
                            model.copyEndpoint()
                        }
                    }
                }

                SettingsCardRow(
                    title: "Local MCP",
                    subtitle: "FastAPI server running locally on localhost"
                ) {
                    StatusBadge(
                        text: model.mcpHealth.rawValue.capitalized,
                        status: model.mcpHealth == .healthy ? .healthy : (model.mcpHealth == .unreachable ? .offline : .warning)
                    )
                }

                SettingsCardRow(
                    title: "Public MCP",
                    subtitle: "ngrok verified public HTTPS connectivity"
                ) {
                    StatusBadge(
                        text: model.tunnelHealth.label,
                        status: model.tunnelHealth == .healthy ? .healthy : (model.tunnelHealth == .connecting ? .warning : .offline)
                    )
                }

                if !model.serviceNotice.isEmpty {
                    SettingsCardRow(
                        title: "Service notice",
                        subtitle: model.serviceNotice
                    ) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                SettingsCardRow(
                    title: "Services control",
                    subtitle: "Restart local backend and refresh ngrok tunnel session",
                    showDivider: false
                ) {
                    SettingsButton(title: "Restart services", icon: "arrow.clockwise", style: .secondary) {
                        model.restartServices()
                    }
                }
            }

            SettingsCard(title: "Permissions & Safety") {
                SettingsCardRow(
                    title: "Emergency stop",
                    subtitle: "Immediately blocks active sessions, cancels terminal jobs, and revokes OAuth tokens. Enforced at SQLite authorization boundary.",
                    showDivider: false
                ) {
                    SettingsToggle(
                        isOn: Binding(
                            get: { model.emergencyStop },
                            set: { model.setEmergencyStop($0) }
                        ),
                        tintColor: Color(red: 0.92, green: 0.26, blue: 0.26)
                    )
                }
            }

            SettingsCard(title: "Approval notifications") {
                SettingsCardRow(
                    title: "Sound alerts",
                    subtitle: "Play sound effect when a new tool approval request arrives"
                ) {
                    SettingsToggle(isOn: $approvalSoundsEnabled)
                }

                SettingsCardRow(
                    title: "macOS notifications",
                    subtitle: "Display notification banner on arrival. Alerts are sent once per newly discovered request; command arguments are excluded.",
                    showDivider: false
                ) {
                    SettingsToggle(isOn: $approvalNotificationsEnabled)
                        .onChange(of: approvalNotificationsEnabled) { _, enabled in
                            if enabled { ApprovalArrivalNotification.requestPermission() }
                        }
                }
            }
        }
    }
}

private struct SecurityDetailView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Emergency controls") {
                SettingsCardRow(
                    title: "Emergency stop",
                    subtitle: "Blocks all command execution, revokes active OAuth tokens, and refuses incoming MCP tool calls. Persisted directly in RelayOS SQLite database.",
                    showDivider: false
                ) {
                    SettingsToggle(
                        isOn: Binding(
                            get: { model.emergencyStop },
                            set: { model.setEmergencyStop($0) }
                        ),
                        tintColor: Color(red: 0.92, green: 0.26, blue: 0.26)
                    )
                }
            }

            SettingsCard(title: "Authorization boundary") {
                SettingsCardRow(
                    title: "Independent local approval",
                    subtitle: "Project sessions and terminal commands require local approval on this Mac. AI client approval tool calls are never accepted without verified local consent."
                ) {
                    StatusBadge(text: "Enforced locally", status: .healthy)
                }

                SettingsCardRow(
                    title: "Database audit trail",
                    subtitle: "All approval decisions, denials, executions, and revoked permissions are recorded in RelayOS local audit tables.",
                    showDivider: false
                ) {
                    StatusBadge(text: "Active", status: .healthy)
                }
            }
        }
    }
}

private struct ConnectionsDetailView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Connected AI clients") {
                if model.connectedClients.isEmpty {
                    SettingsCardRow(
                        title: "No connected AI clients",
                        subtitle: "Add RelayOS's MCP endpoint URL to ChatGPT, Claude, or other MCP clients to start pair programming."
                    ) {
                        StatusBadge(text: "Waiting", status: .neutral)
                    }
                } else {
                    ForEach(Array(model.connectedClients.enumerated()), id: \.offset) { _, name in
                        SettingsCardRow(
                            title: name,
                            subtitle: "Authenticated MCP client session"
                        ) {
                            StatusBadge(text: "Connected", status: .healthy)
                        }
                    }
                }

                SettingsCardRow(
                    title: "MCP endpoint URL",
                    subtitle: "The public HTTPS URL configured for client connections",
                    showDivider: false
                ) {
                    SettingsButton(title: "Copy MCP endpoint", icon: "doc.on.doc", style: .primary) {
                        model.copyEndpoint()
                    }
                }
            }
        }
    }
}

private struct NgrokDetailView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "ngrok transport") {
                SettingsCardRow(
                    title: "Tunnel process",
                    subtitle: "Local ngrok daemon process status"
                ) {
                    StatusBadge(
                        text: model.tunnelRunning ? "Running" : "Stopped",
                        status: model.tunnelRunning ? .healthy : .offline
                    )
                }

                SettingsCardRow(
                    title: "Public health",
                    subtitle: "Public tunnel health verified via unauthenticated HTTP 401 check"
                ) {
                    StatusBadge(
                        text: model.tunnelHealth.label,
                        status: model.tunnelHealth == .healthy ? .healthy : (model.tunnelHealth == .connecting ? .warning : .offline)
                    )
                }

                SettingsCardRow(
                    title: "Configured endpoint",
                    subtitle: model.endpoint
                ) {
                    SettingsButton(title: "Copy", icon: "doc.on.doc", style: .secondary) {
                        model.copyEndpoint()
                    }
                }

                SettingsCardRow(
                    title: "Session reconnect",
                    subtitle: "A running ngrok process alone does not prove connectivity. Click reconnect to cycle tunnel processes.",
                    showDivider: false
                ) {
                    SettingsButton(title: "Reconnect", icon: "arrow.clockwise", style: .secondary) {
                        model.restartServices()
                    }
                }
            }
        }
    }
}

private struct ToolsDetailView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Available tools") {
                SettingsCardRow(
                    title: "Project tools",
                    subtitle: "Enable workspace filesystem and development tools for connected AI clients"
                ) {
                    SettingsToggle(isOn: $model.projectTools)
                }

                SettingsCardRow(
                    title: "Persist configuration",
                    subtitle: "Save tool preferences to disk",
                    showDivider: false
                ) {
                    SettingsButton(title: "Save tool settings", style: .secondary) {
                        model.saveCapabilities()
                    }
                }
            }

            SettingsCard(title: "Persistent folder grants") {
                if model.permissionGrants.isEmpty {
                    SettingsCardRow(
                        title: "No persistent permissions yet",
                        subtitle: "Permissions granted with 'Always' appear here for inspection and revocation.",
                        showDivider: false
                    ) {
                        Text("None")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.5))
                    }
                } else {
                    ForEach(Array(model.permissionGrants.enumerated()), id: \.offset) { _, grant in
                        SettingsCardRow(
                            title: (grant["grant_type"] as? String ?? "permission").capitalized,
                            subtitle: grant["scope"] as? String ?? ""
                        ) {
                            SettingsButton(title: "Revoke", style: .destructive) {
                                if let id = grant["token"] as? String {
                                    model.revokePermission(id)
                                }
                            }
                        }
                    }

                    SettingsCardRow(
                        title: "Revoke all",
                        subtitle: "Revoke every persistent folder permission immediately",
                        showDivider: false
                    ) {
                        SettingsButton(title: "Revoke all permissions", style: .destructive) {
                            for grant in model.permissionGrants {
                                if let id = grant["token"] as? String {
                                    model.revokePermission(id)
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "macOS system permissions") {
                SettingsCardRow(
                    title: "Screen recording",
                    subtitle: "Managed by macOS Privacy & Security. Screen capture tools require user authorization in System Settings.",
                    showDivider: false
                ) {
                    SettingsButton(title: "Open Privacy & Security", icon: "lock.shield", style: .secondary) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Main Settings View

struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var selected: SettingsTab = .general
    @State private var searchText: String = ""

    private var pageTitle: String { selected.rawValue }

    var body: some View {
        HStack(spacing: 0) {
            CustomSidebarView(model: model, selected: $selected, searchText: $searchText)

            Rectangle()
                .fill(Color(white: 0.14))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 20)

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
            .background(Color(red: 0.095, green: 0.095, blue: 0.095))
        }
        .background(CustomWindowAccessor())
        .onChange(of: model.approvalNavigationRequest) { _, _ in
            selected = .approvals
        }
    }

    @ViewBuilder
    private func tabDetailView(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralDetailView(model: model)
        case .appearance:
            RelayOSAppearanceView()
        case .security:
            SecurityDetailView(model: model)
        case .approvals:
            ApprovalCenterView(model: model)
        case .activity:
            ApprovalCenterView(model: model, initialShowingHistory: true)
        case .connections:
            ConnectionsDetailView(model: model)
        case .ngrok:
            NgrokDetailView(model: model)
        case .tools:
            ToolsDetailView(model: model)
        case .commandPermissions:
            CommandPermissionsView(model: model)
        case .terminalJobs:
            CommandJobsView(model: model)
        }
    }
}

// MARK: - Settings Tab Enum

enum SettingsTab: String, Hashable, CaseIterable {
    case general = "General"
    case appearance = "Appearance"
    case security = "Security"
    case approvals = "Approvals"
    case activity = "Activity"
    case connections = "Connections"
    case ngrok = "ngrok transport"
    case tools = "Tools & permissions"
    case commandPermissions = "Command permissions"
    case terminalJobs = "Terminal jobs"
}
