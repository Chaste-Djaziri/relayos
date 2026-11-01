import SwiftUI

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
        .ignoresSafeArea()
        .background(CustomWindowAccessor())
    }
}
