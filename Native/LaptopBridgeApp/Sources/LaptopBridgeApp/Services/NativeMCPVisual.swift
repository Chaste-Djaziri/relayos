// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPVisual.swift
import AppKit
import SwiftUI
import CoreGraphics

/// Native screen observation is denied unless macOS has already granted the
/// Debug app Screen Recording permission and the user approved this exact call.
enum NativeScreenCapture {
    enum CaptureError: Error { case permissionRequired, captureUnavailable, tooLarge }

    static func snapshot() throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionRequired }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw CaptureError.captureUnavailable
        }
        let source = NSBitmapImageRep(cgImage: image)
        let targetWidth = min(image.width, 1200)
        let targetHeight = max(1, Int(Double(image.height) * Double(targetWidth) / Double(image.width)))
        let size = NSSize(width: targetWidth, height: targetHeight)
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count < 3_000_000 else {
            throw CaptureError.tooLarge
        }
        return ["mime_type": "image/png", "data": png.base64EncodedString(),
                "width": targetWidth, "height": targetHeight]
    }
}

/// A visible, non-intercepting native overlay; no remote pointer or keyboard
/// actions are implemented. This only draws hints and can always be dismissed
/// by clicking Clear in RelayOS.
@MainActor
final class NativeGuidanceOverlay {
    static let shared = NativeGuidanceOverlay()
    private var window: NSPanel?

    func show(message: String, normalizedX: Double, normalizedY: Double) {
        guard message.utf8.count <= 600, message.contains(where: { !$0.isNewline }),
              normalizedX.isFinite, normalizedY.isFinite,
              (0...1).contains(normalizedX), (0...1).contains(normalizedY),
              let screen = NSScreen.main else { return }
        clear()
        let frame = screen.frame
        let width: CGFloat = 360, height: CGFloat = 124
        let left = frame.minX + CGFloat(normalizedX) * max(0, frame.width - width)
        let bottom = frame.minY + CGFloat(normalizedY) * max(0, frame.height - height)
        let panel = NSPanel(
            contentRect: NSRect(x: left, y: bottom, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16)))
        panel.orderFrontRegardless()
        window = panel
    }

    func clear() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}
