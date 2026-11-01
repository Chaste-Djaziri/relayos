import SwiftUI

struct CustomSidebarView: View {
    @ObservedObject var model: BridgeModel
    @Binding var selected: SettingsTab
    @Binding var searchText: String

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

