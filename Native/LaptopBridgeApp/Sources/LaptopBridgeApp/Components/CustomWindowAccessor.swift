import SwiftUI
import AppKit

struct CustomWindowAccessor: NSViewRepresentable {
    var sidebarTransparency: Bool = true
    var isDark: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        if sidebarTransparency {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = isDark
                ? NSColor(red: 0.095, green: 0.095, blue: 0.095, alpha: 1.0)
                : NSColor(red: 0.955, green: 0.955, blue: 0.965, alpha: 1.0)
        }
    }
}
