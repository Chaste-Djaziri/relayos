// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/RelayOSLiveLessonObserver.swift
import AppKit
import CoreGraphics
import SwiftUI

struct RelayOSLessonVerification: Decodable {
    let kind: String
    let bundle_id: String?
}

struct RelayOSLessonSnapshot: Decodable {
    let active: Bool
    let status: String
    let session_id: String?
    let goal: String?
    let step_index: Int?
    let total_steps: Int?
    let instruction: String?
    let verify: RelayOSLessonVerification?
    let expires_at: Double?
}

/// Passive, explicitly approved action metadata collection.
/// No key characters, input values, window titles or clipboard contents are
/// read, transmitted or stored. Monitors exist only while a lesson is active.
@MainActor
final class RelayOSLiveLessonObserver: ObservableObject {
    static let shared = RelayOSLiveLessonObserver()

    @Published private(set) var snapshot: RelayOSLessonSnapshot?
    private var timer: Timer?
    private var globalMonitor: Any?
    private var activationMonitor: NSObjectProtocol?
    private var polling = false
    private var generation = 0
    private var lastSent: [String: Date] = [:]
    private var sessionID: String?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let tick = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        snapshot = nil
        detach()
    }

    private func request(_ suffix: String = "", method: String = "GET",
                         payload: [String: Any]? = nil) -> URLRequest? {
        guard let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/guided-lesson" + suffix)
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        if let payload {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        return req
    }

    private func poll() {
        guard !polling, let req = request() else { return }
        polling = true
        let expected = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.polling = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard expected == self.generation,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let latest = try JSONDecoder().decode(RelayOSLessonSnapshot.self, from: data)
                self.snapshot = latest
                if latest.active, let session = latest.session_id {
                    if self.sessionID != session {
                        self.detach()
                        self.sessionID = session
                        self.attach()
                    }
                    // An app may already be open when a new step starts;
                    // re-check foreground bundle at a low rate, not a guess.
                    self.send(kind: "app_active", minInterval: 4)
                } else {
                    self.detach()
                }
            } catch {
                // No local server means no valid observation channel.
                self.detach()
                self.snapshot = nil
            }
        }
    }

    private func attach() {
        guard globalMonitor == nil, activationMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) {
                [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    self.send(kind: "click", minInterval: 0.3)
                case .scrollWheel:
                    if abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) >= 0.1 {
                        self.send(kind: "scroll", minInterval: 0.7)
                    }
                case .keyDown:
                    // Report only that a key action happened. Never touch
                    // event.characters, keyCode, modifiers or field values.
                    self.send(kind: "typing", minInterval: 1.0)
                default:
                    break
                }
            }
        }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(kind: "app_active", minInterval: 0)
            }
        }
    }

    private func detach() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        if let observer = activationMonitor {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activationMonitor = nil
        sessionID = nil
        lastSent.removeAll()
    }

    private func send(kind: String, minInterval: TimeInterval) {
        guard snapshot?.active == true, let session = sessionID,
              let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundle.count <= 150 else { return }
        let key = kind + ":" + bundle
        let now = Date()
        guard now.timeIntervalSince(lastSent[key] ?? .distantPast) >= minInterval else { return }
        lastSent[key] = now
        var payload: [String: Any] = [
            "session_id": session, "kind": kind, "bundle_id": bundle,
        ]
        if kind == "click", let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == CGMainDisplayID()
        }) {
            let pos = NSEvent.mouseLocation
            let frame = screen.frame
            let x = Double((pos.x - frame.minX) / frame.width)
            let y = Double(1 - (pos.y - frame.minY) / frame.height)
            if (0...1).contains(x) && (0...1).contains(y) {
                payload["x"] = x
                payload["y"] = y
            }
        }
        guard let req = request("/event", method: "POST", payload: payload) else { return }
        Task {
            // Acks are not interpreted as user success unless the backend
            // independently matches the current declared verification step.
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func action(_ name: String) {
        guard ["pause", "resume", "stop", "confirm"].contains(name),
              let session = snapshot?.session_id,
              let req = request("/action", method: "POST",
                                payload: ["action": name, "session_id": session]) else { return }
        Task { @MainActor [weak self] in
            _ = try? await URLSession.shared.data(for: req)
            self?.poll()
        }
    }
}

#if DEBUG
#Preview("Lesson status") {
    Text("RelayOS live lesson action observer")
        .padding()
}
#endif
