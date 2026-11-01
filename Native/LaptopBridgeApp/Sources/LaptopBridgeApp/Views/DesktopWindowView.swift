import SwiftUI

struct DesktopWindowView: View {
    @ObservedObject var model: BridgeModel
    @AppStorage(RelayOSTheme.sidebarTransparencyKey) private var sidebarTransparency = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if model.endpoint == "Not configured" {
                FreshSetupView(model: model)
            } else {
                SettingsView(model: model)
            }
        }
        .ignoresSafeArea()
        .background(
            CustomWindowAccessor(
                sidebarTransparency: sidebarTransparency,
                isDark: colorScheme == .dark
            )
        )
    }
}

#if DEBUG
#Preview("RelayOS · Main window") {
    DesktopWindowView(model: BridgeModel.preview())
        .frame(width: 1160, height: 780)
}
#endif
