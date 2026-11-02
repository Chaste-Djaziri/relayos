// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/App/RelayOSCursorTip.swift
import AppKit
import SwiftUI

/// Local, bounded instruction delivered through the authenticated RelayOS
/// cursor-guidance endpoint. Never interactive and never recorded to disk.
struct RelayOSCursorTip: Decodable {
    let id: String
    let text: String
    let expiresAt: TimeInterval
    let targetID: String?

    enum CodingKeys: String, CodingKey {
        case id, text
        case expiresAt = "expires_at"
        case targetID = "target_id"
    }

    func isValid(at date: Date) -> Bool {
        !id.isEmpty && id.count <= 128 &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.count <= 240 && text.utf8.count <= 1000 &&
        expiresAt.isFinite && date.timeIntervalSince1970 < expiresAt
    }
}

enum RelayOSCursorTipAnimation {
    static let charactersPerSecond = 32.0

    static func characterCount(elapsed: TimeInterval, total: Int) -> Int {
        guard elapsed.isFinite, total >= 0 else { return 0 }
        return min(total, max(0, Int(max(0, elapsed) * charactersPerSecond)))
    }

    static func displayedText(_ message: String, elapsed: TimeInterval) -> String {
        String(message.prefix(characterCount(elapsed: elapsed, total: message.count)))
    }
}

enum RelayOSCursorTipPlacement {
    static let size = CGSize(width: 292, height: 116)
    static let gutter: CGFloat = 12
    static let inset: CGFloat = 8

    /// Attach beside the virtual marker and flip to stay entirely on-screen.
    /// Uses the macOS bottom-left global coordinate space for multi-display use.
    static func frame(near marker: CGRect, screen: CGRect) -> CGRect {
        let right = marker.maxX + gutter
        let left = marker.minX - gutter - size.width
        let x = right + size.width + inset <= screen.maxX ? right : left
        let suggestedY = marker.midY - size.height / 2
        return CGRect(
            x: min(max(x, screen.minX + inset),
                   max(screen.minX + inset, screen.maxX - size.width - inset)),
            y: min(max(suggestedY, screen.minY + inset),
                   max(screen.minY + inset, screen.maxY - size.height - inset)),
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class RelayOSCursorTipPresentation: ObservableObject {
    @Published var visible = true
}

struct RelayOSCursorTipView: View {
    let message: String
    let startedAt: Date
    @ObservedObject var presentation: RelayOSCursorTipPresentation
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let shown = RelayOSCursorTipAnimation.displayedText(message, elapsed: elapsed)
            let isTyping = shown.count < message.count
            let blink = Int(elapsed * 2.5) % 2 == 0
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayOSTheme.accent(accent))
                    Text("RELAYOS")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(RelayOSTheme.accent(accent))
                        .frame(width: 5, height: 5)
                }
                HStack(alignment: .top, spacing: 0) {
                    Text(shown)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if isTyping && blink {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(RelayOSTheme.accent(accent))
                            .frame(width: 2, height: 14)
                            .padding(.leading, 2)
                    }
                }
                .frame(height: 67, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .frame(width: RelayOSCursorTipPlacement.size.width,
                   height: RelayOSCursorTipPlacement.size.height, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(RelayOSTheme.accent(accent).opacity(0.45),
                                  lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .opacity(presentation.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: presentation.visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private final class RelayOSCursorTipWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small, passive panel that tracks the actual *virtual* cursor position;
/// it never captures the screen or receives keyboard/mouse events.
@MainActor
final class RelayOSCursorTipCompanion {
    private var window: RelayOSCursorTipWindow?
    private var presentation: RelayOSCursorTipPresentation?
    private(set) var activeID: String?

    func show(_ tip: RelayOSCursorTip, near marker: CGRect, on screen: CGRect) {
        guard tip.isValid(at: Date()) else {
            dismiss()
            return
        }
        if activeID != tip.id {
            dismiss(immediately: true)
            let placement = RelayOSCursorTipPlacement.frame(near: marker, screen: screen)
            let panel = RelayOSCursorTipWindow(
                contentRect: placement,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.sharingType = .none
            let model = RelayOSCursorTipPresentation()
            panel.contentView = NSHostingView(rootView: RelayOSCursorTipView(
                message: tip.text, startedAt: Date(), presentation: model))
            window = panel
            presentation = model
            activeID = tip.id
            panel.orderFrontRegardless()
        } else if let panel = window {
            let placement = RelayOSCursorTipPlacement.frame(near: marker, screen: screen)
            if panel.frame != placement { panel.setFrame(placement, display: true) }
        }
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
            model?.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                old.orderOut(nil)
                old.close()
            }
        }
    }
}

#if DEBUG
#Preview("RelayOS · Typing cursor tip") {
    RelayOSCursorTipView(
        message: "The profile switcher is in the top-left corner. Click here to open it.",
        startedAt: .now.addingTimeInterval(-2),
        presentation: RelayOSCursorTipPresentation()
    )
    .frame(width: 330, height: 150)
    .padding(18)
}
#endif
