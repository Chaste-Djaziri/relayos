import Foundation

struct SidebarItemModel: Identifiable {
    var id: SettingsTab { tab }
    let tab: SettingsTab
    let title: String
    let icon: String
}
