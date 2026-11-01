import SwiftUI

struct CustomSidebarView: View {
    @ObservedObject var model: BridgeModel
    @Binding var selected: SettingsTab
    @Binding var searchText: String

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.sidebarTransparencyKey) private var sidebarTransparency = true
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private let generalItems: [SidebarItemModel] = [
        SidebarItemModel(tab: .general, title: "General", icon: "gearshape"),
        SidebarItemModel(tab: .appearance, title: "Appearance", icon: "paintpalette"),
        SidebarItemModel(tab: .security, title: "Security", icon: "lock.shield"),
        SidebarItemModel(tab: .systemPermissions, title: "System permissions", icon: "hand.raised.fill"),
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
            CustomTrafficLights()
                .padding(.top, 14)
                .padding(.leading, 16)
                .padding(.bottom, 14)

            Text("Settings")
                .font(.system(size: 18 * scale, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textSecondary)

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: max(28, 28 * scale))
            .background(theme.sidebarSearchBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    let filteredGeneral = generalItems.filter { matchesSearch($0) }
                    if !filteredGeneral.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("General")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
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

                    let filteredAccess = accessItems.filter { matchesSearch($0) }
                    if !filteredAccess.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Integrations & Approvals")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
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

                    let filteredTools = toolItems.filter { matchesSearch($0) }
                    if !filteredTools.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Execution & Tools")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
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
        .frame(width: max(224, 224 * scale))
        .background {
            if sidebarTransparency {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            } else {
                theme.sidebarOpaqueBackground
            }
        }
    }

    private func matchesSearch(_ item: SidebarItemModel) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let keywords: String
        switch item.tab {
        case .general: keywords = "endpoint connection public mcp local restart notifications sound"
        case .appearance: keywords = "theme light dark color typography font size reduce motion translucent"
        case .security: keywords = "emergency stop revocation safety"
        case .systemPermissions: keywords = "screen recording full disk access accessibility apple events files privacy"
        case .approvals: keywords = "once session always deny pending"
        case .activity: keywords = "audit history executed errors logs"
        case .connections: keywords = "oauth client authorized mcp endpoint"
        case .ngrok: keywords = "transport tunnel public connecting stopped"
        case .tools: keywords = "capabilities project tools folder grants"
        case .commandPermissions: keywords = "git grant executable command scope"
        case .terminalJobs: keywords = "stdout stderr progress cancel background jobs"
        }
        return item.title.localizedCaseInsensitiveContains(query) ||
            keywords.localizedCaseInsensitiveContains(query)
    }
}

#if DEBUG
#Preview("Navigation sidebar") {
    CustomSidebarView(model: BridgeModel.preview(), selected: .constant(.general), searchText: .constant(""))
        .frame(width: 290, height: 710)
}
#endif
