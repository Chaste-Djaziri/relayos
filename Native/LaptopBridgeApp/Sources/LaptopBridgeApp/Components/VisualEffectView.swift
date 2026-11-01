import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

#if DEBUG
#Preview("Sidebar material") {
    ZStack {
        VisualEffectView(material: .sidebar)
        VStack(alignment: .leading, spacing: 12) {
            Label("General", systemImage: "gearshape")
            Label("Appearance", systemImage: "paintpalette")
        }.padding()
    }.frame(width: 270, height: 180)
}
#endif
