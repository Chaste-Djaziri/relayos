// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSGuidanceNotepad.swift
import AppKit
import SwiftUI

/// Authenticated read-only local snapshot. The window never executes scripts
/// and never reads or writes arbitrary files or screen contents.
struct RelayOSBoardElement: Decodable, Identifiable {
    let id: String
    let kind: String
    let x: Double
    let y: Double
    let w: Double?
    let h: Double?
    let text: String?
    let points: [[Double]]?
    let color: String
    let font_size: Double?
    let stroke_width: Double?

    func ink() -> Color {
        switch color {
        case "white": return .white
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        default: return RelayOSTheme.accent(
            UserDefaults.standard.string(forKey: RelayOSTheme.accentKey) ?? "blue")
        }
    }
}

struct RelayOSBoardSnapshot: Decodable {
    let active: Bool
    let visible: Bool
    let id: String?
    let title: String?
    let width: Int?
    let height: Int?
    let expires_at: Double?
    let revision: Int
    let elements: [RelayOSBoardElement]?

    var canvasWidth: CGFloat { CGFloat(width ?? 1000) }
    var canvasHeight: CGFloat { CGFloat(height ?? 1200) }
}

struct RelayOSNotepadElementView: View {
    let item: RelayOSBoardElement
    let width: CGFloat
    let height: CGFloat

    private var x: CGFloat { CGFloat(item.x) * width }
    private var y: CGFloat { CGFloat(item.y) * height }
    private var w: CGFloat { CGFloat(item.w ?? 0.1) * width }
    private var h: CGFloat { CGFloat(item.h ?? 0.1) * height }
    private var stroke: CGFloat { CGFloat(item.stroke_width ?? 3) }

    var body: some View {
        Group {
            if item.kind == "text" || item.kind == "code" {
                Text(item.text ?? "")
                    .font(.system(size: CGFloat(item.font_size ?? 20),
                                  weight: item.kind == "code" ? .medium : .semibold,
                                  design: item.kind == "code" ? .monospaced : .default))
                    .foregroundStyle(item.ink())
                    .frame(width: w, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(item.kind == "code" ? 12 : 0)
                    .background(item.kind == "code" ? Color.black.opacity(0.58) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .offset(x: x, y: y)
            } else if item.kind == "rect" {
                Rectangle().stroke(item.ink(), lineWidth: stroke)
                    .frame(width: w, height: h).offset(x: x, y: y)
            } else if item.kind == "ellipse" {
                Ellipse().stroke(item.ink(), lineWidth: stroke)
                    .frame(width: w, height: h).offset(x: x, y: y)
            } else if item.kind == "line" || item.kind == "arrow" {
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: w, y: h))
                    if item.kind == "arrow" {
                        let angle = atan2(h, w)
                        let head: CGFloat = 17
                        let first = CGPoint(x: w - head * cos(angle - .pi / 6),
                                            y: h - head * sin(angle - .pi / 6))
                        let second = CGPoint(x: w - head * cos(angle + .pi / 6),
                                             y: h - head * sin(angle + .pi / 6))
                        path.move(to: first)
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.addLine(to: second)
                    }
                }
                .stroke(item.ink(), style: StrokeStyle(lineWidth: stroke, lineCap: .round,
                                                       lineJoin: .round))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
            } else if item.kind == "path", let points = item.points {
                Path { path in
                    guard let first = points.first, first.count == 2 else { return }
                    path.move(to: CGPoint(x: first[0] * width, y: first[1] * height))
                    for point in points.dropFirst() where point.count == 2 {
                        path.addLine(to: CGPoint(x: point[0] * width, y: point[1] * height))
                    }
                }
                .stroke(item.ink(), style: StrokeStyle(lineWidth: stroke, lineCap: .round,
                                                       lineJoin: .round))
                .frame(width: width, height: height)
            }
        }
        .accessibilityLabel(item.kind == "text" || item.kind == "code"
                            ? item.text ?? "" : "Visual annotation: \(item.kind)")
    }
}

/// Scrolls independently of the guided app. The user can move or resize the
/// containing NSPanel and can clear or hide the canvas at any time.
struct RelayOSNotepadCanvas: View {
    let board: RelayOSBoardSnapshot

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var grid = Path()
                    stride(from: CGFloat(0), through: size.width, by: 40).forEach { x in
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    stride(from: CGFloat(0), through: size.height, by: 40).forEach { y in
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.075)), lineWidth: 1)
                }
                .allowsHitTesting(false)
                ForEach(board.elements ?? []) { item in
                    RelayOSNotepadElementView(item: item, width: board.canvasWidth,
                                              height: board.canvasHeight)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: board.canvasWidth, height: board.canvasHeight,
                   alignment: .topLeading)
            .background(Color(red: 0.085, green: 0.105, blue: 0.14))
        }
        .scrollIndicators(.visible)
        .background(Color.black.opacity(0.92))
    }
}

struct RelayOSNotepadWindowView: View {
    @ObservedObject var model: RelayOSGuidanceNotepad
    @ObservedObject private var lesson = RelayOSLiveLessonObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "pencil.and.scribble").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.board?.title ?? "RelayOS Notepad")
                        .font(.system(size: 15, weight: .bold))
                    Text("Drag the title bar • Resize • Scroll to explore")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let status = lesson.snapshot, status.status == "active" || status.status == "paused" {
                    Text("\(status.step_index.map { $0 + 1 } ?? 0)/\(status.total_steps ?? 0)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    if status.verify?.kind == "manual" && status.active {
                        Button("Done") { lesson.action("confirm") }
                            .help("Manually confirm this exercise is complete")
                    }
                    Button(status.active ? "Pause" : "Resume") {
                        lesson.action(status.active ? "pause" : "resume")
                    }
                    Button("Stop") { lesson.action("stop") }
                }
                Button("Clear") { model.sendAction("clear") }
                    .help("Erase all canvas annotations")
                Button("Hide") { model.sendAction("hide") }
                    .help("Move the notepad out of the way")
            }
            .padding(12)
            .background(.regularMaterial)

            if let board = model.board, board.active {
                RelayOSNotepadCanvas(board: board)
            } else {
                ContentUnavailableView("No active notepad",
                                       systemImage: "pencil.and.scribble",
                                       description: Text("Ask ChatGPT to open the RelayOS guidance notepad."))
            }
        }
        .frame(minWidth: 380, minHeight: 250)
    }
}

@MainActor
final class RelayOSGuidanceNotepad: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RelayOSGuidanceNotepad()
    @Published private(set) var board: RelayOSBoardSnapshot?

    private var window: NSPanel?
    private var timer: Timer?
    private var requestInFlight = false
    private var generation = 0

    private override init() { super.init() }

    func start() {
        guard timer == nil else { return }
        let tick = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        poll()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        board = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func request(_ suffix: String = "", method: String = "GET",
                         body: [String: Any]? = nil) -> URLRequest? {
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/guidance-notepad" + suffix)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 160, y: 200, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "RelayOS · Teaching Notepad"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 250)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = NSHostingView(rootView: RelayOSNotepadWindowView(model: self))
        panel.delegate = self
        window = panel
    }

    private func poll() {
        guard !requestInFlight, let request = request() else { return }
        requestInFlight = true
        let expected = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.requestInFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard self.generation == expected,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let latest = try JSONDecoder().decode(RelayOSBoardSnapshot.self, from: data)
                if latest.revision != self.board?.revision || latest.id != self.board?.id {
                    self.board = latest
                }
                if latest.active && latest.visible {
                    self.makeWindowIfNeeded()
                    if self.window?.isVisible != true { self.window?.orderFrontRegardless() }
                } else {
                    self.window?.orderOut(nil)
                }
            } catch {
                // If the MCP helper is disconnected, hide stale remote drawings.
                self.board = nil
                self.window?.orderOut(nil)
            }
        }
    }

    func sendAction(_ action: String) {
        guard ["hide", "show", "clear", "close"].contains(action),
              let request = request("/action", method: "POST", body: ["action": action])
        else { return }
        if action == "hide" || action == "close" { window?.orderOut(nil) }
        Task { @MainActor [weak self] in
            _ = try? await URLSession.shared.data(for: request)
            self?.poll()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sendAction("hide")
        return false
    }
}

#if DEBUG
#Preview("RelayOS Notepad") {
    RelayOSNotepadWindowView(model: .shared)
        .frame(width: 640, height: 460)
}
#endif
