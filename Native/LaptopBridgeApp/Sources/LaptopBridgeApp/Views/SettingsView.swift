import SwiftUI

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
        .ignoresSafeArea()
        .background(CustomWindowAccessor())
        .onChange(of: model.approvalNavigationRequest) { _, _ in
            selected = .approvals
        }
    }

    @ViewBuilder
    private func tabDetailView(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralPageView(model: model)
        case .appearance:
            RelayOSAppearanceView()
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

