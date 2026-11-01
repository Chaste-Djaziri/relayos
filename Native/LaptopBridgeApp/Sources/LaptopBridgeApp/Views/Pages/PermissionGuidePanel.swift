// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/Pages/PermissionGuidePanel.swift
import SwiftUI
import AppKit

// Small, user-dismissible native guide. System Settings remains responsible for
// granting access; drag and drop never changes macOS permissions directly.
@MainActor
final class PermissionGuidePanel {
    static let shared = PermissionGuidePanel()
    private var window: NSPanel?

    func present(for permission: SystemPermissionKind) {
        window?.close()
        let guide = PermissionDragGuideView(permission: permission) { [weak self] in
            self?.dismiss()
        }
        let frame = NSRect(x: 0, y: 0, width: 350, height: 300)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "RelayOS Permission Guide"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: guide)
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 28,
                                         y: visible.maxY - frame.height - 44))
        } else {
            panel.center()
        }
        window = panel
        panel.orderFrontRegardless()
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

private struct PermissionDragGuideView: View {
    let permission: SystemPermissionKind
    let close: () -> Void
    @AppStorage(RelayOSTheme.modeKey) private var appearance = "system"

    // The running signed app is the permission subject. Do not advertise a
    // development executable or arbitrary path as an app drag source.
    private var appURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.square")
                    .foregroundStyle(.secondary)
                Text(permission.title).font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close permission guide")
            }

            Text(permission.instructions)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if permission.supportsAppDrag, let url = appURL {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 52, height: 52)
                        Text("RelayOS.app")
                            .font(.caption.weight(.semibold))
                        Text("Drag into Settings if supported")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .onDrag { NSItemProvider(object: url as NSURL) }
                    .accessibilityLabel("RelayOS application. Drag into the macOS permission list if supported.")
                    Spacer()
                }
            } else {
                Text("Use System Settings to enable this permission. Not every macOS permission list supports dragging apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                if let url = appURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Spacer()
                Button("Done") { close() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 350, height: 300)
        .preferredColorScheme(RelayOSTheme.scheme(appearance))
    }
}
