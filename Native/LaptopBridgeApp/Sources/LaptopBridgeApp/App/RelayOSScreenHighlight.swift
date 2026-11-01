// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSScreenHighlight.swift
import AppKit
import SwiftUI

/// Decoded only from the token-authenticated local RelayOS control API.
/// All geometry refers to one full display, normalized from its top-left.
struct RelayOSHighlightSpec: Decodable {
    let shape: String
    let bounds: [Double]       // left, top, width, height
    let points: [[Double]]     // path vertices, top-left origin
    let closed: Bool
    let cornerRadius: Double
    let fillOpacity: Double
    let strokeWidth: Double

    enum CodingKeys: String, CodingKey {
        case shape, bounds, points, closed
        case cornerRadius = "corner_radius"
        case fillOpacity = "fill_opacity"
        case strokeWidth = "stroke_width"
    }

    var isValid: Bool {
        let shapes = ["rect", "rounded_rect", "ellipse", "polygon", "path"]
        guard shapes.contains(shape), bounds.count == 4,
              bounds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              bounds[0] + bounds[2] <= 1.000001, bounds[1] + bounds[3] <= 1.000001,
              cornerRadius.isFinite, (0...40).contains(cornerRadius),
              fillOpacity.isFinite, (0...0.25).contains(fillOpacity),
              strokeWidth.isFinite, (1...6).contains(strokeWidth),
              points.count <= 96 else { return false }
        if shape == "polygon" || shape == "path" {
            guard points.count >= (closed ? 3 : 2),
                  shape != "polygon" || closed else { return false }
            return points.allSatisfy { p in
                p.count == 2 && p.allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
        }
        return bounds[2] > 0 && bounds[3] > 0 && points.isEmpty
    }

    var center: CGPoint {
        CGPoint(x: bounds[0] + bounds[2] / 2, y: bounds[1] + bounds[3] / 2)
    }

    var hasFill: Bool { closed && fillOpacity > 0 }
}

enum RelayOSHighlightGeometry {
    /// SwiftUI display overlays are top-left-origin, unlike global macOS
    /// pointer coordinates. This function is shared by render and hit tests.
    static func path(for region: RelayOSHighlightSpec, in rect: CGRect) -> Path {
        guard region.isValid else { return Path() }
        let b = region.bounds
        let regionRect = CGRect(x: rect.minX + CGFloat(b[0]) * rect.width,
                                y: rect.minY + CGFloat(b[1]) * rect.height,
                                width: CGFloat(b[2]) * rect.width, height: CGFloat(b[3]) * rect.height)
        var path = Path()
        switch region.shape {
        case "rect":
            // Begin at upper-left; trim animates clockwise from this corner.
            path.move(to: CGPoint(x: regionRect.minX, y: regionRect.minY))
            path.addLine(to: CGPoint(x: regionRect.maxX, y: regionRect.minY))
            path.addLine(to: CGPoint(x: regionRect.maxX, y: regionRect.maxY))
            path.addLine(to: CGPoint(x: regionRect.minX, y: regionRect.maxY))
            path.closeSubpath()
        case "rounded_rect":
            let r = min(CGFloat(region.cornerRadius),
                        regionRect.width / 2, regionRect.height / 2)
            // Start at the top-left edge rather than the default roundedRect
            // path's platform-dependent start point.
            let x = regionRect.minX, y = regionRect.minY
            let maxX = regionRect.maxX, maxY = regionRect.maxY
            path.move(to: CGPoint(x: x + r, y: y))
            path.addLine(to: CGPoint(x: maxX - r, y: y))
            path.addQuadCurve(to: CGPoint(x: maxX, y: y + r),
                              control: CGPoint(x: maxX, y: y))
            path.addLine(to: CGPoint(x: maxX, y: maxY - r))
            path.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY),
                              control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: x + r, y: maxY))
            path.addQuadCurve(to: CGPoint(x: x, y: maxY - r),
                              control: CGPoint(x: x, y: maxY))
            path.addLine(to: CGPoint(x: x, y: y + r))
            path.addQuadCurve(to: CGPoint(x: x + r, y: y),
                              control: CGPoint(x: x, y: y))
            path.closeSubpath()
        case "ellipse":
            path.addEllipse(in: regionRect)
        case "polygon", "path":
            guard let first = region.points.first else { return Path() }
            func position(_ p: [Double]) -> CGPoint {
                CGPoint(x: rect.minX + CGFloat(p[0]) * rect.width,
                        y: rect.minY + CGFloat(p[1]) * rect.height)
            }
            path.move(to: position(first))
            for p in region.points.dropFirst() { path.addLine(to: position(p)) }
            if region.closed { path.closeSubpath() }
        default:
            break
        }
        return path
    }

    static func isNear(
        pointer: CGPoint, region: RelayOSHighlightSpec,
        screen: CGRect, radius: CGFloat
    ) -> Bool {
        guard region.isValid, radius.isFinite, (0...200).contains(radius) else { return false }
        let local = CGPoint(x: pointer.x - screen.minX,
                            y: screen.maxY - pointer.y)
        let path = path(for: region, in: CGRect(origin: .zero, size: screen.size))
        if region.closed && path.contains(local) { return true }
        let corridor = path.strokedPath(StrokeStyle(
            lineWidth: max(1, radius * 2), lineCap: .round, lineJoin: .round))
        return corridor.contains(local)
    }
}

@MainActor
final class RelayOSHighlightPresentation: ObservableObject {
    @Published var isVisible = true
}

private struct RelayOSHighlightShape: Shape {
    let region: RelayOSHighlightSpec

    func path(in rect: CGRect) -> Path {
        RelayOSHighlightGeometry.path(for: region, in: rect)
    }
}

struct RelayOSHighlightView: View {
    let region: RelayOSHighlightSpec
    @ObservedObject var presentation: RelayOSHighlightPresentation
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @State private var drawn: CGFloat = 0
    @State private var showFill = false

    var body: some View {
        GeometryReader { _ in
            let shape = RelayOSHighlightShape(region: region)
            ZStack {
                if region.hasFill {
                    shape.fill(RelayOSTheme.accent(accent).opacity(region.fillOpacity))
                        .opacity(showFill ? 1 : 0)
                }
                shape.trim(from: 0, to: drawn)
                    .stroke(RelayOSTheme.accent(accent),
                            style: StrokeStyle(lineWidth: CGFloat(region.strokeWidth),
                                               lineCap: .round, lineJoin: .round))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(presentation.isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.65).delay(0.18)) { drawn = 1 }
            withAnimation(.easeIn(duration: 0.25).delay(0.76)) { showFill = true }
        }
        .animation(.easeOut(duration: 0.20), value: presentation.isVisible)
    }
}

private final class RelayOSHighlightWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Separate transparent overlay so the small triangle window never needs to
/// expand to full-screen. Neither panel accepts clicks or key focus.
@MainActor
final class RelayOSScreenHighlight {
    private var window: RelayOSHighlightWindow?
    private var presentation: RelayOSHighlightPresentation?
    private(set) var activeID: String?

    func show(id: String, region: RelayOSHighlightSpec, on screen: NSScreen) {
        guard region.isValid else { dismiss(immediately: true); return }
        if activeID == id { return }
        dismiss(immediately: true)
        let panel = RelayOSHighlightWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Screen capture should observe the underlying app, not RelayOS's
        // own visual annotation. This panel is local visual guidance only.
        panel.sharingType = .none
        let model = RelayOSHighlightPresentation()
        panel.contentView = NSHostingView(
            rootView: RelayOSHighlightView(region: region, presentation: model))
        window = panel
        presentation = model
        activeID = id
        panel.orderFrontRegardless()
    }

    func dismiss(immediately: Bool = false) {
        guard let old = window else { return }
        window = nil
        activeID = nil
        let model = presentation
        presentation = nil
        if immediately {
            old.orderOut(nil)
            old.close()
        } else {
            model?.isVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                old.orderOut(nil)
                old.close()
            }
        }
    }
}

#if DEBUG
#Preview("RelayOS · Highlight region") {
    let sample = RelayOSHighlightSpec(
        shape: "rounded_rect", bounds: [0.15, 0.25, 0.65, 0.4],
        points: [], closed: true, cornerRadius: 12,
        fillOpacity: 0.12, strokeWidth: 2.5)
    RelayOSHighlightView(region: sample, presentation: RelayOSHighlightPresentation())
        .frame(width: 420, height: 230)
        .background(.gray.opacity(0.15))
}
#endif
