import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var selected: SettingsTab = .general
    @State private var searchText: String = ""

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(RelayOSTheme.sidebarTransparencyKey) private var sidebarTransparency = true
    @AppStorage(RelayOSTheme.fontSizeKey) private var userFontSize = 14.0

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(userFontSize)
    }

    private var pageTitle: String { selected.rawValue }

    var body: some View {
        HStack(spacing: 0) {
            CustomSidebarView(model: model, selected: $selected, searchText: $searchText)

            Rectangle()
                .fill(theme.cardDivider)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 20)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(pageTitle)
                            .font(.system(size: 30 * scale, weight: .semibold))
                            .tracking(-0.7)
                            .foregroundStyle(theme.textPrimary)

                        if model.isDevelopmentClient {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "hammer.fill")
                                Text(model.isSwiftOnly
                                     ? "Swift-only local development · No Python or ngrok started. Unported settings are disabled."
                                     : "Xcode development · Live settings and approvals. This app observes the installed MCP service without restarting it. Approval and revocation actions can affect live permissions.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(theme.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                        }

                        tabDetailView(selected)
                            .allowsHitTesting(!model.isPreview || selected == .appearance)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.windowBackground)
        }
        .ignoresSafeArea()
        .background(
            CustomWindowAccessor(
                sidebarTransparency: sidebarTransparency,
                isDark: colorScheme == .dark
            )
        )
        .onChange(of: model.approvalNavigationRequest) { _, _ in
            selected = .approvals
        }
    }

    @ViewBuilder
    private func tabDetailView(_ tab: SettingsTab) -> some View {
        if model.isSwiftOnly {
            switch tab {
            case .general:
                NativeSwiftRuntimePageView(model: model)
            case .appearance:
                AppearancePageView()
            default:
                SettingsCard(title: "Not yet available in native Swift") {
                    SettingsCardRow(
                        title: tab.rawValue,
                        subtitle: "This feature is still being migrated. Running Xcode in Swift-only mode will never launch its Python helper.",
                        showDivider: false
                    ) {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    }
                }
            }
        } else {
        switch tab {
        case .general:
            GeneralPageView(model: model)
        case .appearance:
            AppearancePageView()
        case .security:
            SecurityPageView(model: model)
        case .systemPermissions:
            SystemPermissionsPageView(model: model)
        case .approvals:
            ApprovalCenterView(model: model)
        case .activity:
            ActivityHistoryView(model: model)
        case .connections:
            ConnectionsPageView(model: model)
        case .ngrok:
            NgrokPageView(model: model)
        case .tools:
            ToolsPageView(model: model)
        case .commandPermissions:
            CommandPermissionsView(model: model)
        case .terminalJobs:
            CommandJobsView(model: model)
        }
        }
    }
}

#if DEBUG
#Preview("Settings · All pages") {
    SettingsView(model: BridgeModel.preview())
        .frame(width: 1160, height: 780)
}
#endif
