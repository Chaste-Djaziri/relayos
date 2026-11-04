// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSOnscreenAnnotations.swift
import AppKit
import SwiftUI
import CoreGraphics

/// Drawings are delivered by the authenticated localhost MCP helper.
/// They are NOT a new window with notes: this component paints directly
/// above the underlying app/display, and never receives mouse or keyboard input.
struct RelayOSScreenInk: Decodable, Identifiable {
    let id: String
    let kind: String
    let display: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let color: String
    let stroke_width: Double
    let opacity: Double
    let expires_at: Double
    let text: String?
    let font_size: Double?
    let points: [[Double]]?
    let only_when_app: String?

    func active(for displayID: CGDirectDisplayID, frontmost: String?, now: Double) -> Bool {
        let matchesDisplay = display == "main" ? displayID == CGMainDisplayID() :
            display == String(displayID)
        return matchesDisplay && expires_at > now &&
            (only_when_app == nil || only_when_app == frontmost)
    }

    func colorValue(accent: String) -> Color {
        switch color {
        case "white": return .white
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        default: return RelayOSTheme.accent(accent)
        }
    }
}

struct RelayOSScreenInkSnapshot: Decodable {
    let active: Bool
    let revision: Int
    let annotations: [RelayOSScreenInk]
}

/// Geometry is normalized in the same top-left coordinate system as an
/// approved full-display screenshot. No guessing about cropped window origins.
enum RelayOSInkGeometry {
    static func drawPath(for item: RelayOSScreenInk, in size: CGSize) -> Path {
        let x = CGFloat(item.x) * size.width
        let y = CGFloat(item.y) * size.height
        let x2 = CGFloat(item.x + item.w) * size.width
        let y2 = CGFloat(item.y + item.h) * size.height
        var path = Path()
        switch item.kind {
        case "rect":
            path.addRect(CGRect(x: x, y: y, width: x2 - x, height: y2 - y))
        case "ellipse":
            path.addEllipse(in: CGRect(x: x, y: y, width: x2 - x, height: y2 - y))
        case "line", "arrow":
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x2, y: y2))
            if item.kind == "arrow" {
                // The endpoint marks the feature being labeled.
                let angle = atan2(y2 - y, x2 - x)
                let head: CGFloat = 17
                let a = CGPoint(x: x2 - head * cos(angle - .pi / 6),
                                y: y2 - head * sin(angle - .pi / 6))
                let b = CGPoint(x: x2 - head * cos(angle + .pi / 6),
                                y: y2 - head * sin(angle + .pi / 6))
                path.move(to: a)
                path.addLine(to: CGPoint(x: x2, y: y2))
                path.addLine(to: b)
            }
        case "path", "scribble":
            if let points = item.points, let first = points.first, first.count == 2 {
                path.move(to: CGPoint(x: first[0] * size.width, y: first[1] * size.height))
                for point in points.dropFirst() where point.count == 2 {
                    path.addLine(to: CGPoint(x: point[0] * size.width, y: point[1] * size.height))
                }
            }
        default:
            break
        }
        return path
    }
}

@MainActor
final class RelayOSInkPresentation: ObservableObject {
    @Published var items: [RelayOSScreenInk] = []
    @Published var revision: Int = -1
}

struct RelayOSOnscreenInkView: View {
    @ObservedObject var presentation: RelayOSInkPresentation
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for item in presentation.items where !["text","label","code"].contains(item.kind) {
                        let path = RelayOSInkGeometry.drawPath(for: item, in: size)
                        // Draw gradually like a marker writing on the display.
                        context.stroke(path.trimmedPath(from: 0, to: progress),
                                       with: .color(item.colorValue(accent: accent).opacity(item.opacity)),
                                       style: StrokeStyle(lineWidth: CGFloat(item.stroke_width),
                                                          lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(presentation.items.filter { ["text","label","code"].contains($0.kind) }) { item in
                    let ink = item.colorValue(accent: accent)
                    Text(item.text ?? "")
                        .font(.system(size: CGFloat(item.font_size ?? 18),
                                      weight: item.kind == "label" ? .bold : .medium,
                                      design: item.kind == "code" ? .monospaced : .rounded))
                        .foregroundStyle(ink)
                        .frame(width: CGFloat(item.w) * geometry.size.width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(item.kind == "label" || item.kind == "code" ? 7 : 0)
                        .background(
                            (item.kind == "label" || item.kind == "code")
                                ? Color.black.opacity(0.82) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                        .opacity(item.opacity)
                        .offset(x: CGFloat(item.x) * geometry.size.width,
                                y: CGFloat(item.y) * geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { animateInk() }
        .onChange(of: presentation.revision) { _, _ in animateInk() }
    }

    private func animateInk() {
        progress = 0
        withAnimation(.easeInOut(duration: 1.45)) { progress = 1 }
    }
}

private final class RelayOSInkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A separate click-through, non-capturable panel per display.
/// The notepad is never launched by on-screen drawing commands.
@MainActor
final class RelayOSOnscreenAnnotations {
    static let shared = RelayOSOnscreenAnnotations()

    private var windows: [CGDirectDisplayID: RelayOSInkPanel] = [:]
    private var models: [CGDirectDisplayID: RelayOSInkPresentation] = [:]
    private var lastSnapshot: RelayOSScreenInkSnapshot?
    private var lastFrontmost: String?
    private var lastRevision: Int = -1
    private var pollTimer: Timer?
    private var polling = false
    private var generation = 0

    private init() {}

    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    func stop() {
        generation += 1
        pollTimer?.invalidate()
        pollTimer = nil
        lastSnapshot = nil
        lastRevision = -1
        closePanels()
    }

    private func closePanels() {
        windows.values.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
        windows.removeAll()
        models.removeAll()
    }

    private func request(_ suffix: String = "", method: String = "GET") -> URLRequest? {
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/screen-annotations" + suffix)
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        return req
    }

    private func poll() {
        // Foreground app is a LOCAL visibility check only. Bundle names are
        // not transmitted or recorded by this feature.
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if foreground != lastFrontmost {
            lastFrontmost = foreground
            if let snapshot = lastSnapshot { render(snapshot) }
        }
        guard !polling, let req = request() else {
            if request() == nil { closePanels() }
            return
        }
        polling = true
        let expected = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.polling = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard self.generation == expected,
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.closePanels()
                    return
                }
                let snapshot = try JSONDecoder().decode(RelayOSScreenInkSnapshot.self, from: data)
                if snapshot.revision != self.lastRevision {
                    self.lastRevision = snapshot.revision
                    self.lastSnapshot = snapshot
                    self.render(snapshot)
                }
            } catch {
                // Fail closed if the MCP helper disconnects.
                self.closePanels()
                self.lastSnapshot = nil
                self.lastRevision = -1
            }
        }
    }

    private func render(_ snapshot: RelayOSScreenInkSnapshot) {
        let now = Date().timeIntervalSince1970
        let screens = NSScreen.screens
        let screenIDs = Set(screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        for id in windows.keys where !screenIDs.contains(id) {
            windows[id]?.orderOut(nil)
            windows[id]?.close()
            windows.removeValue(forKey: id)
            models.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? NSNumber)?.uint32Value else { continue }
            let items = snapshot.annotations.filter {
                $0.active(for: id, frontmost: lastFrontmost, now: now)
            }
            guard !items.isEmpty else {
                windows[id]?.orderOut(nil)
                continue
            }
            if windows[id] == nil {
                let panel = RelayOSInkPanel(contentRect: screen.frame,
                                           styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = .statusBar
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.sharingType = .none
                let presentation = RelayOSInkPresentation()
                panel.contentView = NSHostingView(rootView: RelayOSOnscreenInkView(
                    presentation: presentation))
                windows[id] = panel
                models[id] = presentation
            }
            windows[id]?.setFrame(screen.frame, display: true)
            let presentation = models[id]
            if presentation?.items.map(\.id) != items.map(\.id) {
                presentation?.items = items
                presentation?.revision = snapshot.revision
            }
            if windows[id]?.isVisible != true { windows[id]?.orderFrontRegardless() }
        }
    }

    func clear() {
        guard let req = request("/clear", method: "POST") else { return }
        closePanels()
        lastSnapshot = nil
        lastRevision = -1
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}

#if DEBUG
#Preview("On-screen labels and scribbles") {
    RelayOSOnscreenInkView(presentation: RelayOSInkPresentation())
        .frame(width: 700, height: 400)
        .background(.gray.opacity(0.18))
}
#endif
