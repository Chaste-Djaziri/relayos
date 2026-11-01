import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject private var notch = NotchPanelCoordinator.shared
    @Environment(\.openWindow) private var openWindow
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
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(model.running ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(model.running ? "Local MCP available" : "Local MCP unavailable")
                                    .font(.system(size: 11 * scale))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Button {
                                model.showApprovalCenter()
                            } label: {
                                Label("Approvals", systemImage: "tray.full")
                                    .font(.system(size: 11 * scale))
                                    .overlay(alignment: .topTrailing) {
                                        if !model.approvalInbox.isEmpty {
                                            Circle().fill(.orange).frame(width: 6, height: 6)
                                                .offset(x: 5, y: -3)
                                        }
                                    }
                            }
                            .buttonStyle(.borderless)
                            if !model.isSwiftOnly {
                                Button {
                                    model.showTerminalJobs()
                                } label: {
                                    Label("Jobs \(model.activeCommandJobsCount > 0 ? "(\(model.activeCommandJobsCount))" : "")",
                                          systemImage: "terminal")
                                        .font(.system(size: 11 * scale))
                                }
                                .buttonStyle(.borderless)
                            }
                            Button {
                                notch.toggle(model: model) {
                                    openWindow(id: "main")
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                            } label: {
                                Label(notch.isVisible ? "Hide notch" : "Notch panel",
                                      systemImage: "rectangle.topthird.inset.filled")
                                    .font(.system(size: 11 * scale))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.bottom, 2)

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
        .onAppear {
            // A menu-bar/notch action can request the inbox before this window
            // is recreated. Honor that intent on first display as well.
            if model.commandJobsNavigationRequest > 0 && !model.isSwiftOnly {
                selected = .terminalJobs
            } else if model.approvalNavigationRequest > 0 {
                selected = model.isSwiftOnly ? .general : .approvals
            }
        }
        .onChange(of: model.approvalNavigationRequest) { _, newValue in
            guard newValue > 0 else { return }
            selected = model.isSwiftOnly ? .general : .approvals
        }
        .onChange(of: model.commandJobsNavigationRequest) { _, newValue in
            guard newValue > 0, !model.isSwiftOnly else { return }
            selected = .terminalJobs
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
