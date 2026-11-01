// Path: Native/LaptopBridgeApp/ScreenCapture/RelayOSScreenCapture.swift
// One-shot ScreenCaptureKit helper. Captures exactly the locally approved
// app, window or display; emits JPEG bytes to stdout and no files to disk.
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureFailure: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .invalidRequest(let reason), .unavailable(let reason): reason
        }
    }
}

enum CaptureScope: String {
    case app
    case window
    case display
}

struct CaptureRequest {
    let scope: CaptureScope
    let target: String
    let maxWidth: Int

    init(arguments: [String]) throws {
        guard arguments.count == 4, arguments[0] == "--capture",
              let scope = CaptureScope(rawValue: arguments[1]),
              let maxWidth = Int(arguments[3]), (320...2400).contains(maxWidth),
              !arguments[2].isEmpty, arguments[2].utf8.count <= 256
        else { throw CaptureFailure.invalidRequest("Invalid capture arguments") }
        self.scope = scope
        self.target = arguments[2]
        self.maxWidth = maxWidth
    }
}

@available(macOS 14.0, *)
enum OneShotScreenCapture {
    static func pick<T>(_ candidates: [T], target: String,
                        label: (T) -> String, identifier: (T) -> String,
                        scope: String) throws -> T {
        let match = candidates.filter {
            label($0).localizedCaseInsensitiveCompare(target) == .orderedSame
            || identifier($0).localizedCaseInsensitiveCompare(target) == .orderedSame
        }
        guard !match.isEmpty else { throw CaptureFailure.unavailable("No matching \\(scope) is open") }
        guard match.count == 1 else { throw CaptureFailure.unavailable("Ambiguous \\(scope); use an exact identifier") }
        return match[0]
    }

    static func filter(for request: CaptureRequest, content: SCShareableContent) throws -> SCContentFilter {
        switch request.scope {
        case .display:
            let display: SCDisplay
            if request.target == "main" {
                guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    throw CaptureFailure.unavailable("Main display is not shareable")
                }
                display = main
            } else {
                display = try pick(content.displays, target: request.target,
                                   label: { String($0.displayID) },
                                   identifier: { String($0.displayID) },
                                   scope: "display")
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            let windows = content.windows.filter { $0.isOnScreen && $0.frame.width > 20 && $0.frame.height > 20 }
            let window = try pick(windows, target: request.target,
                                  label: { $0.title ?? "" },
                                  identifier: { String($0.windowID) },
                                  scope: "window")
            return SCContentFilter(desktopIndependentWindow: window)
        case .app:
            let app = try pick(content.applications, target: request.target,
                               label: { $0.applicationName },
                               identifier: { $0.bundleIdentifier },
                               scope: "application")
            let windows = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.isOnScreen }
            guard !windows.isEmpty else {
                throw CaptureFailure.unavailable("The selected app has no visible windows")
            }
            // Capture only the selected application's windows. Nothing from
            // other applications or the desktop is included.
            let display = content.displays.first { display in
                windows.contains { $0.frame.intersects(display.frame) }
            } ?? content.displays.first
            guard let display else { throw CaptureFailure.unavailable("No display available") }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
    }

    static func take(_ request: CaptureRequest) async throws -> Data {
        // This executable is invoked ONLY after the user approves a single
        // screenshot in the local inbox. Request macOS permission at that
        // moment, never at RelayOS startup or when merely proposing a capture.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.unavailable(
                "Screen Recording permission is required. Grant it to RelayOS in System Settings > Privacy & Security > Screen & System Audio Recording, then restart RelayOS."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let selection = try filter(for: request, content: content)
        let rect = selection.contentRect
        let scale = CGFloat(selection.pointPixelScale)
        guard rect.width > 0, rect.height > 0, scale > 0 else {
            throw CaptureFailure.unavailable("Selected content has invalid dimensions")
        }
        let originalWidth = rect.width * scale
        let originalHeight = rect.height * scale
        let outputWidth = min(CGFloat(request.maxWidth), originalWidth)
        let outputHeight = max(1, round(originalHeight * outputWidth / originalWidth))
        let settings = SCStreamConfiguration()
        settings.width = Int(outputWidth)
        settings.height = Int(outputHeight)
        settings.showsCursor = false
        settings.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: selection, configuration: settings)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let result = bitmap.representation(
            using: .jpeg, properties: [.compressionFactor: 0.83]),
              result.count > 100, result.count <= 4_000_000 else {
            throw CaptureFailure.unavailable("Captured image exceeded the 4 MB safety limit")
        }
        return result
    }
}

@main
struct RelayOSScreenCaptureMain {
    static func main() async {
        do {
            let request = try CaptureRequest(arguments: Array(CommandLine.arguments.dropFirst()))
            let data = try await OneShotScreenCapture.take(request)
            // The only stdout content is the image. No temp files, previews,
            // click tracking, repeated frames or audio capture.
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("Capture failed: \\(error)\n".utf8))
            exit(1)
        }
    }
}
