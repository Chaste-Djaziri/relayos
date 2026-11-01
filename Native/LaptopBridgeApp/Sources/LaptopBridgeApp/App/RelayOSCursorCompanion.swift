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

/// Equal-length sides, centered in the cursor's click-through panel.
/// The frame may be taller than the triangle, but the actual path is always
/// equilateral, regardless of the available preview/window dimensions.
struct RelayOSCursorTriangle: Shape {
    static let heightFactor: CGFloat = sqrt(3) / 2

    static func vertices(in rect: CGRect) -> [CGPoint] {
        let side = min(rect.width, rect.height / heightFactor)
        let height = side * heightFactor
        let left = rect.midX - side / 2
        let top = rect.midY - height / 2
        let bottom = rect.midY + height / 2
        return [
            CGPoint(x: rect.midX, y: top),
            CGPoint(x: left + side, y: bottom),
            CGPoint(x: left, y: bottom)
        ]
    }

    func path(in rect: CGRect) -> Path {
        let points = Self.vertices(in: rect)
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.closeSubpath()
        return path
    }
}

struct RelayOSCursorMarkerView: View {
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"

    var body: some View {
        RelayOSCursorTriangle()
            .fill(RelayOSTheme.accent(accent))
            .accessibilityHidden(true)
    }
}

/// Critically damped follow motion. It accelerates gently from rest and
/// decelerates naturally after the real mouse stops, without a trailing
/// Core Animation transaction that could interfere with future frames.
struct RelayOSCursorMotion {
    private(set) var position: CGPoint?
    private(set) var velocity = CGVector.zero
    private var lastTick: TimeInterval?
    private var lastScreen: CGRect?

    private static let angularFrequency: CGFloat = 29

    mutating func reset() {
        position = nil
        velocity = .zero
        lastTick = nil
        lastScreen = nil
    }

    mutating func advance(to target: CGRect, screen: CGRect, at time: TimeInterval) -> CGRect {
        guard time.isFinite else {
            reset()
            return target
        }
        guard let current = position, let previous = lastTick,
              lastScreen == screen, time > previous, time - previous <= 0.35
        else {
            position = target.origin
            velocity = .zero
            lastTick = time
            lastScreen = screen
            return target
        }

        let dt = CGFloat(time - previous)
        let omega = Self.angularFrequency
        let decay = exp(-omega * dt)

        // Analytical solution for a critically damped spring, one axis at a
        // time; independent of timer variability or the pointer's frame rate.
        func easedAxis(_ p: CGFloat, _ v: CGFloat, _ goal: CGFloat) -> (CGFloat, CGFloat) {
            let displacement = p - goal
            let transient = (v + omega * displacement) * dt
            let next = goal + (displacement + transient) * decay
            let nextVelocity = (v - omega * transient) * decay
            if abs(next - goal) < 0.08 && abs(nextVelocity) < 0.8 {
                return (goal, 0)
            }
            return (next, nextVelocity)
        }

        let (x, vx) = easedAxis(current.x, velocity.dx, target.origin.x)
        let (y, vy) = easedAxis(current.y, velocity.dy, target.origin.y)
        let minimumX = screen.minX + RelayOSCursorPlacement.edgeInset
        let maximumX = max(minimumX, screen.maxX - target.width - RelayOSCursorPlacement.edgeInset)
        let minimumY = screen.minY + RelayOSCursorPlacement.edgeInset
        let maximumY = max(minimumY, screen.maxY - target.height - RelayOSCursorPlacement.edgeInset)
        let bounded = CGPoint(x: min(max(x, minimumX), maximumX),
                              y: min(max(y, minimumY), maximumY))
        position = bounded
        velocity = CGVector(dx: bounded.x == x ? vx : 0,
                            dy: bounded.y == y ? vy : 0)
        lastTick = time
        return CGRect(origin: bounded, size: target.size)
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
    private var motion = RelayOSCursorMotion()

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
        motion.reset()
    }

    private func updatePosition() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.map(\.frame)
        guard let screen = screens.first(where: { $0.contains(pointer) }),
              let target = RelayOSCursorPlacement.frame(for: pointer, on: screens)
        else {
            window.orderOut(nil)
            lastFrame = nil
            motion.reset()
            return
        }
        let frame = motion.advance(
            to: target, screen: screen, at: ProcessInfo.processInfo.systemUptime
        )
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
