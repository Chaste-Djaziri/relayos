// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/RelayOSWalkthroughObserver.swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only local observation. No input synthesis, screenshots, arbitrary
/// screen text, or file access. Only the fixed General item in System Settings
/// is inspected; unrelated accessibility tree content is never transmitted.
struct RelayOSWalkthroughStatus: Decodable {
    let id: String?
    let flow: String?
    let status: String
    let active: Bool?
    let step: Int?
    let totalSteps: Int?
    let instruction: String?
    let attentionNeeded: Bool?
    let expiresInSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, flow, status, active, step, instruction
        case totalSteps = "total_steps"
        case attentionNeeded = "attention_needed"
        case expiresInSeconds = "expires_in_seconds"
    }
}

struct RelayOSGeneralObservation: Equatable {
    let frontmostBundleID: String
    let accessibility: Bool
    let generalSelected: Bool
    let generalBounds: [Double]?

    var isSystemSettingsFrontmost: Bool {
        frontmostBundleID == "com.apple.systempreferences"
    }
}

/// Can be unit-tested without macOS Accessibility or a real System Settings UI.
enum RelayOSWalkthroughRules {
    static func shouldReport(status: RelayOSWalkthroughStatus, observation: RelayOSGeneralObservation) -> Bool {
        guard status.status == "active", status.id != nil else { return false }
        return status.step == 0 || status.step == 1
    }
}

private enum RelayOSSystemSettingsInspector {
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func text(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }

    private static func selected(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSelectedAttribute as String) as? Bool) == true
    }

    private static func bounds(_ element: AXUIElement, on main: CGRect) -> [Double]? {
        guard let pValue = attribute(element, kAXPositionAttribute as String),
              let sValue = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(pValue) == AXValueGetTypeID(),
              CFGetTypeID(sValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sValue as! AXValue, .cgSize, &size),
              size.width >= 10, size.height >= 8, main.width > 0, main.height > 0 else { return nil }
        // Accessibility positions are in global top-left coordinates. For the
        // primary display (whose origin is 0,0) these match screenshot pixels.
        // Never guess a rectangle on secondary displays.
        let x = Double((point.x - main.minX) / main.width)
        let y = Double(point.y / main.height)
        let w = Double(size.width / main.width)
        let h = Double(size.height / main.height)
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite,
              (0...1).contains(x), (0...1).contains(y),
              w > 0, h > 0, x + w <= 1, y + h <= 1 else { return nil }
        return [x, y, w, h]
    }

    static func inspect() -> RelayOSGeneralObservation {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .init(frontmostBundleID: "", accessibility: AXIsProcessTrusted(),
                         generalSelected: false, generalBounds: nil)
        }
        let bundle = app.bundleIdentifier ?? ""
        guard bundle == "com.apple.systempreferences" else {
            return .init(frontmostBundleID: bundle, accessibility: AXIsProcessTrusted(),
                         generalSelected: false, generalBounds: nil)
        }
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            return .init(frontmostBundleID: bundle, accessibility: false,
                         generalSelected: false, generalBounds: nil)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let mainScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == CGMainDisplayID()
        }
        let screen = mainScreen?.frame ?? .zero
        var queue: [(AXUIElement, Int, Bool)] = windows.map { ($0, 0, false) }
        var visited = 0
        var candidateBounds: [Double]?
        while !queue.isEmpty && visited < 400 {
            let (element, depth, ancestorSelected) = queue.removeFirst()
            visited += 1
            if depth > 12 { continue }
            let selectedHere = ancestorSelected || selected(element)
            let title = text(element, kAXTitleAttribute as String) ??
                text(element, kAXDescriptionAttribute as String) ??
                text(element, kAXValueAttribute as String)
            if title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "general" {
                // A window can also be titled "General". Never mistake its
                // large rectangle for the sidebar control, or infer that its
                // title means the General category was actually selected.
                let role = text(element, kAXRoleAttribute as String)
                if role == "AXRow" || role == "AXButton" || role == "AXStaticText" ||
                    role == "AXCell" || role == "AXOutlineRow" {
                    let itemBounds = bounds(element, on: screen)
                    if selectedHere {
                        return .init(frontmostBundleID: bundle, accessibility: true,
                                     generalSelected: true, generalBounds: itemBounds)
                    }
                    if candidateBounds == nil { candidateBounds = itemBounds }
                }
            }
            if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(45).map { ($0, depth + 1, selectedHere) })
            }
        }
        return .init(frontmostBundleID: bundle, accessibility: true,
                     generalSelected: false, generalBounds: candidateBounds)
    }
}

@MainActor
final class RelayOSWalkthroughObserver: ObservableObject {
    static let shared = RelayOSWalkthroughObserver()

    @Published private(set) var status = RelayOSWalkthroughStatus(
        id: nil, flow: nil, status: "idle", active: false, step: nil,
        totalSteps: nil, instruction: nil, attentionNeeded: nil, expiresInSeconds: nil)

    private var timer: Timer?
    private var polling = false
    private var observationInFlight = false
    private var lastObservedStep: Int?
    private var lastObservedID: String?
    private var lastObservedBounds: [Double]?
    private var lastObservedBundleID: String?
    private var lastObservedSelected: Bool?
    private var lastObservedAccessibility: Bool?
    private var generation = 0

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        polling = false
        observationInFlight = false
        lastObservedStep = nil
        lastObservedID = nil
        lastObservedBounds = nil
        lastObservedBundleID = nil
        lastObservedSelected = nil
        lastObservedAccessibility = nil
        status = .init(id: nil, flow: nil, status: "idle", active: false, step: nil,
                       totalSteps: nil, instruction: nil, attentionNeeded: nil,
                       expiresInSeconds: nil)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/walkthrough" + path)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func poll() {
        guard timer != nil, !polling, let req = request("") else { return }
        polling = true
        let currentGeneration = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.polling = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard self.generation == currentGeneration,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let next = try JSONDecoder().decode(RelayOSWalkthroughStatus.self, from: data)
                self.status = next
                guard next.status == "active", next.id != nil else { return }
                self.observe(next)
            } catch {
                // A disconnected MCP host cannot advance a walkthrough. Never
                // assume an action succeeded because the app was unresponsive.
            }
        }
    }

    private func observe(_ stage: RelayOSWalkthroughStatus) {
        guard !observationInFlight, let id = stage.id else { return }
        observationInFlight = true
        let currentGeneration = generation
        let observer = self
        Task.detached(priority: .utility) {
            let observation = RelayOSSystemSettingsInspector.inspect()
            await MainActor.run {
                observer.observationInFlight = false
                guard observer.generation == currentGeneration, observer.status.id == id,
                      RelayOSWalkthroughRules.shouldReport(status: stage, observation: observation) else { return }
                // Avoid posting the same static frame more than once per step.
                if observer.lastObservedID == id && observer.lastObservedStep == stage.step &&
                    observer.lastObservedBundleID == observation.frontmostBundleID &&
                    observer.lastObservedBounds == observation.generalBounds &&
                    observer.lastObservedSelected == observation.generalSelected &&
                    observer.lastObservedAccessibility == observation.accessibility { return }
                observer.lastObservedID = id
                observer.lastObservedStep = stage.step
                observer.lastObservedBounds = observation.generalBounds
                observer.lastObservedBundleID = observation.frontmostBundleID
                observer.lastObservedSelected = observation.generalSelected
                observer.lastObservedAccessibility = observation.accessibility
                var body: [String: Any] = [
                    "id": id,
                    "frontmost_bundle_id": observation.frontmostBundleID,
                    "accessibility": observation.accessibility,
                    "general_selected": observation.generalSelected
                ]
                if let bounds = observation.generalBounds { body["general_bounds"] = bounds }
                guard let req = observer.request("/observe", method: "POST", body: body) else { return }
                Task {
                    _ = try? await URLSession.shared.data(for: req)
                    observer.poll()
                }
            }
        }
    }

    /// Pause, resume or stop from a click in the local RelayOS control center.
    func control(_ action: String) {
        guard ["pause", "resume", "stop"].contains(action),
              let id = status.id, let req = request("/control", method: "POST",
                                                     body: ["action": action, "id": id])
        else { return }
        Task { @MainActor [weak self] in
            _ = try? await URLSession.shared.data(for: req)
            self?.poll()
        }
    }
}
