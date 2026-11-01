// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSCursorCompanion.swift
import AppKit
import CoreGraphics
import SwiftUI

/// Pure placement logic for the passive cursor companion. NSScreen and
/// NSEvent.mouseLocation use the same global bottom-left coordinate space.
enum RelayOSCursorPlacement {
    // Expanded transparent window gives the 24pt triangle room to rotate 360°
    // without clipping when its tip points left, right or diagonally.
    static let size = CGSize(width: 38, height: 38)
    static let offset = CGPoint(x: 16, y: -16)
    static let edgeInset: CGFloat = 2
    // The real mouse entering this radius around the pointed-at item ends
    // visual guidance. Kept independent from the marker's 46pt standoff.
    static let arrivalRadius: CGFloat = 64

    static func arrived(pointer: CGPoint, at target: CGPoint) -> Bool {
        hypot(pointer.x - target.x, pointer.y - target.y) <= arrivalRadius
    }

    static func point(in screen: CGRect, x: Double, y: Double) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        // Captures are top-left-origin; NSScreen's global coordinates are
        // bottom-left-origin, including displays with negative origins.
        return CGPoint(x: screen.minX + CGFloat(x) * screen.width,
                       y: screen.maxY - CGFloat(y) * screen.height)
    }

    static func framePointing(at target: CGPoint, from current: CGPoint, on screen: CGRect) -> CGRect {
        let dx = target.x - current.x
        let dy = target.y - current.y
        let distance = hypot(dx, dy)
        let ux: CGFloat = distance > 0.01 ? dx / distance : 0
        let uy: CGFloat = distance > 0.01 ? dy / distance : 1
        // Stop short of the control: keep its text and hit target unobscured.
        let standoff: CGFloat = 46
        let x = target.x - ux * standoff - size.width / 2
        let y = target.y - uy * standoff - size.height / 2
        let minX = screen.minX + edgeInset
        let minY = screen.minY + edgeInset
        return CGRect(
            x: min(max(x, minX), max(minX, screen.maxX - size.width - edgeInset)),
            y: min(max(y, minY), max(minY, screen.maxY - size.height - edgeInset)),
            width: size.width, height: size.height
        )
    }

    static func rotationToward(target: CGPoint, from center: CGPoint) -> Double {
        let dx = target.x - center.x, dy = target.y - center.y
        guard hypot(dx, dy) > 0.01 else { return 0 }
        // Upward triangle is zero rotation. SwiftUI positive rotation is
        // clockwise; global display Y is upward.
        return atan2(Double(dx), Double(dy))
    }

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

@MainActor
final class RelayOSCursorPresentation: ObservableObject {
    @Published var angle: Double = 0
}

struct RelayOSCursorMarkerView: View {
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @ObservedObject var presentation: RelayOSCursorPresentation

    var body: some View {
        RelayOSCursorTriangle()
            .fill(RelayOSTheme.accent(accent))
            .frame(width: 24, height: 27)
            .rotationEffect(.radians(presentation.angle))
            .frame(width: RelayOSCursorPlacement.size.width,
                   height: RelayOSCursorPlacement.size.height)
            .accessibilityHidden(true)
    }
}

/// Smooth shortest-arc rotation, avoiding a 360° spin when crossing ±π.
struct RelayOSCursorOrientation {
    private(set) var angle: Double = 0
    private var lastTime: TimeInterval?

    mutating func reset() {
        angle = 0
        lastTime = nil
    }

    mutating func advance(toward target: Double, at time: TimeInterval) -> Double {
        guard target.isFinite, time.isFinite else { return angle }
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        let delta = atan2(sin(target - angle), cos(target - angle))
        let alpha = 1 - exp(-18 * dt)
        angle += delta * alpha
        return angle
    }
}

/// The marker remains at its target until the real mouse enters the
/// proximity radius from outside. If already close, the user must move out
/// and return, so guidance does not vanish immediately when it appears.
struct RelayOSCursorArrivalGate {
    private(set) var hasBeenOutside = false

    mutating func reset(isInside: Bool) {
        hasBeenOutside = !isInside
    }

    mutating func update(isInside: Bool) -> Bool {
        if !isInside {
            hasBeenOutside = true
            return false
        }
        return hasBeenOutside
    }

    mutating func reset(pointer: CGPoint, target: CGPoint) {
        reset(isInside: RelayOSCursorPlacement.arrived(pointer: pointer, at: target))
    }

    mutating func update(pointer: CGPoint, target: CGPoint) -> Bool {
        update(isInside: RelayOSCursorPlacement.arrived(pointer: pointer, at: target))
    }
}

/// Only the native UI consumes this ephemeral command. It cannot inject input.
struct RelayOSPointerGuidance: Decodable {
    let active: Bool
    let id: String?
    let display: String?
    let x: Double?
    let y: Double?
    let expiresAt: Double?
    let region: RelayOSHighlightSpec?
    let proximityRadius: Double?
    let showCursor: Bool?

    enum CodingKeys: String, CodingKey {
        case active, id, display, x, y, region
        case expiresAt = "expires_at"
        case proximityRadius = "proximity_radius"
        case showCursor = "show_cursor"
    }

    func targetScreen(in screens: [NSScreen]) -> NSScreen? {
        guard active, let display else { return nil }
        let wantedID = display == "main" ? CGMainDisplayID() : UInt32(display)
        guard let wantedID else { return nil }
        return screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == wantedID
        }
    }

    func point(in screen: CGRect, now: TimeInterval) -> CGPoint? {
        guard active, let expiresAt, now < expiresAt,
              let x, let y else { return nil }
        return RelayOSCursorPlacement.point(in: screen, x: x, y: y)
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
    private var orientation = RelayOSCursorOrientation()
    private let presentation = RelayOSCursorPresentation()
    private var guidance: RelayOSPointerGuidance?
    private var polling = false
    private var lastPoll: TimeInterval = 0
    private var pollGeneration = 0
    private var anchoredID: String?
    private var anchoredFrame: CGRect?
    private var arrivalGate = RelayOSCursorArrivalGate()
    private var dismissedID: String?
    private let highlight = RelayOSScreenHighlight()

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
        window.contentView = NSHostingView(rootView: RelayOSCursorMarkerView(presentation: presentation))
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
        orientation.reset()
        presentation.angle = 0
        guidance = nil
        anchoredID = nil
        anchoredFrame = nil
        arrivalGate = RelayOSCursorArrivalGate()
        dismissedID = nil
        polling = false
        lastPoll = 0
        pollGeneration += 1
        highlight.dismiss(immediately: true)
    }

    private func finishGuidance(_ id: String) {
        // Keep the released marker following the mouse locally even if the
        // acknowledgement is delayed. Never dismiss a newer target by ID.
        dismissedID = id
        guidance = nil
        anchoredID = nil
        anchoredFrame = nil
        arrivalGate = RelayOSCursorArrivalGate()
        highlight.dismiss()
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/cursor-guidance/arrived"),
              let body = try? JSONSerialization.data(withJSONObject: ["id": id])
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        request.httpBody = body
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    private func pollGuidanceIfNeeded(at uptime: TimeInterval) {
        guard !polling, uptime - lastPoll >= 0.4 else { return }
        lastPoll = uptime
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/cursor-guidance")
        else {
            guidance = nil
            return
        }
        polling = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        let generation = pollGeneration
        Task { @MainActor [weak self] in
            guard let self, self.pollGeneration == generation else { return }
            defer { self.polling = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.guidance = nil
                    return
                }
                let command = try JSONDecoder().decode(RelayOSPointerGuidance.self, from: data)
                // Never resurrect a target after closing or on a stale reply.
                guard self.timer != nil else { return }
                self.guidance = command.active && command.id != self.dismissedID
                    ? command : nil
                // A new server-side target may resume guidance after release.
                if command.active && command.id != self.dismissedID {
                    self.dismissedID = nil
                }
            } catch {
                self.guidance = nil
            }
        }
    }

    private func updatePosition() {
        guard let window else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        pollGuidanceIfNeeded(at: uptime)
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let now = Date().timeIntervalSince1970
        var targetPoint: CGPoint?
        var chosenScreen: CGRect?
        var targetFrame: CGRect?
        var highlightShouldRemain = false

        if let command = guidance, let id = command.id,
           let selected = command.targetScreen(in: screens),
           let point = command.point(in: selected.frame, now: now) {
            if anchoredID != id {
                // Anchor one location relative to the user's current pointer.
                // Keep the destination fixed even as the marker approaches
                // it or the real pointer moves elsewhere.
                anchoredID = id
                let center = motion.position.map {
                    CGPoint(x: $0.x + RelayOSCursorPlacement.size.width / 2,
                            y: $0.y + RelayOSCursorPlacement.size.height / 2)
                } ?? pointer
                anchoredFrame = RelayOSCursorPlacement.framePointing(
                    at: point, from: center, on: selected.frame)
                let inside: Bool
                if let region = command.region, region.isValid {
                    let radius = CGFloat(command.proximityRadius ?? 48)
                    inside = RelayOSHighlightGeometry.isNear(
                        pointer: pointer, region: region,
                        screen: selected.frame, radius: radius)
                } else {
                    inside = RelayOSCursorPlacement.arrived(pointer: pointer, at: point)
                }
                arrivalGate.reset(isInside: inside)
            }
            let inside: Bool
            if let region = command.region, region.isValid {
                inside = RelayOSHighlightGeometry.isNear(
                    pointer: pointer, region: region, screen: selected.frame,
                    radius: CGFloat(command.proximityRadius ?? 48))
            } else {
                inside = RelayOSCursorPlacement.arrived(pointer: pointer, at: point)
            }
            if arrivalGate.update(isInside: inside) {
                finishGuidance(id)
            } else {
                if let region = command.region, region.isValid {
                    highlight.show(id: id, region: region, on: selected)
                    highlightShouldRemain = true
                }
                if command.showCursor != false {
                    chosenScreen = selected.frame
                    targetPoint = point
                    targetFrame = anchoredFrame
                }
            }
        } else if guidance != nil {
            guidance = nil
            anchoredID = nil
            anchoredFrame = nil
            arrivalGate = RelayOSCursorArrivalGate()
        }

        if !highlightShouldRemain { highlight.dismiss() }

        if targetFrame == nil {
            let frames = screens.map(\.frame)
            guard let follows = frames.first(where: { $0.contains(pointer) }),
                  let normalFrame = RelayOSCursorPlacement.frame(for: pointer, on: frames)
            else {
                window.orderOut(nil)
                lastFrame = nil
                motion.reset()
                return
            }
            chosenScreen = follows
            targetFrame = normalFrame
        }
        guard let screen = chosenScreen, let target = targetFrame else { return }
        let frame = motion.advance(to: target, screen: screen, at: uptime)
        let pointingAngle: Double
        if let targetPoint {
            pointingAngle = RelayOSCursorPlacement.rotationToward(
                target: targetPoint,
                from: CGPoint(x: frame.midX, y: frame.midY))
        } else {
            pointingAngle = 0
        }
        let angle = orientation.advance(toward: pointingAngle, at: uptime)
        if abs(presentation.angle - angle) > 0.0001 {
            presentation.angle = angle
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
    RelayOSCursorMarkerView(presentation: RelayOSCursorPresentation())
        .frame(width: RelayOSCursorPlacement.size.width,
               height: RelayOSCursorPlacement.size.height)
        .padding(25)
        .background(Color.gray.opacity(0.23))
}
#endif
