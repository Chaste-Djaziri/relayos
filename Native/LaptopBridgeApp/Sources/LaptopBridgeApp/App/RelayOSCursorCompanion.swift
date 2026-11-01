// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSCursorCompanion.swift
import AppKit
import SwiftUI

/// Pure placement logic for the passive cursor companion. NSScreen and
/// NSEvent.mouseLocation use the same global bottom-left coordinate space.
enum RelayOSCursorPlacement {
    static let size = CGSize(width: 24, height: 27)
    static let offset = CGPoint(x: 16, y: -16)
    static let edgeInset: CGFloat = 2

    static func frame(for pointer: CGPoint, on screens: [CGRect]) -> CGRect? {
        // The cursor must be on a display: never put an overlay on an
        // unconnected screen or accidentally teleport it across displays.
        guard let screen = screens.first(where: { $0.contains(pointer) }) else {
            return nil
        }
        let targetX = pointer.x + offset.x
        let targetY = pointer.y + offset.y - size.height

        // Keep the marker visible near display edges without replacing or
        // blocking the real system pointer.
        let left = screen.minX + edgeInset
        let right = max(left, screen.maxX - size.width - edgeInset)
        let bottom = screen.minY + edgeInset
        let top = max(bottom, screen.maxY - size.height - edgeInset)
        return CGRect(
            x: min(max(targetX, left), right),
            y: min(max(targetY, bottom), top),
            width: size.width,
            height: size.height
        )
    }
}

/// A simple triangular RelayOS marker pointing toward the real cursor's
/// position, not a replacement for macOS's pointer.
struct RelayOSCursorTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.07))
        path.addLine(to: CGPoint(x: rect.width * 0.88, y: rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height * 0.91))
        path.closeSubpath()
        return path
    }
}

struct RelayOSCursorMarkerView: View {
    var body: some View {
        RelayOSCursorTriangle()
            .fill(Color(red: 0.43, green: 0.89, blue: 1.00))
            .overlay {
                RelayOSCursorTriangle()
                    .stroke(Color.black.opacity(0.96), style: StrokeStyle(lineWidth: 2.1, lineJoin: .round))
            }
            .shadow(color: .black.opacity(0.38), radius: 2, x: 1, y: 1)
            .accessibilityHidden(true)
    }
}

private final class RelayOSCursorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows a tiny, click-through marker whenever the RelayOS app is running.
/// This uses public mouse position polling only: no event taps, accessibility
/// permissions, screen recording, click injection, or control over other apps.
@MainActor
final class RelayOSCursorCompanion {
    static let shared = RelayOSCursorCompanion()

    private var window: RelayOSCursorWindow?
    private var timer: Timer?
    private var lastFrame: CGRect?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let window = RelayOSCursorWindow(
            contentRect: CGRect(origin: .zero, size: RelayOSCursorPlacement.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: RelayOSCursorMarkerView())
        self.window = window
        updatePosition()

        // Common modes continue updating over menus and while RelayOS is not
        // frontmost. Avoid installing a system-wide event monitor.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        lastFrame = nil
    }

    private func updatePosition() {
        guard let window else { return }
        let frames = NSScreen.screens.map(\.frame)
        guard let frame = RelayOSCursorPlacement.frame(
            for: NSEvent.mouseLocation, on: frames
        ) else {
            window.orderOut(nil)
            lastFrame = nil
            return
        }
        if frame != lastFrame {
            window.setFrame(frame, display: true)
            lastFrame = frame
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }
}

#if DEBUG
#Preview("RelayOS cursor · Triangle") {
    RelayOSCursorMarkerView()
        .frame(width: RelayOSCursorPlacement.size.width,
               height: RelayOSCursorPlacement.size.height)
        .padding(25)
        .background(Color.gray.opacity(0.23))
}
#endif
