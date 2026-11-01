// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeGuidanceSessions.swift
import Foundation
import CoreGraphics

/// One bounded, consented screen-guidance session in the native app.
/// The approval to start it is consumed by NativeMCPActions; these follow-up
/// operations require an exact, unexpired session token.
final class NativeGuidanceSessions {
    static let shared = NativeGuidanceSessions()
    enum SessionError: Error { case denied, expired }

    private struct Session {
        let id: String
        let started: Date
        let expires: Date
        var lastCapture: Date?
    }
    private let lock = NSLock()
    private var activeSession: Session?

    func start(duration: TimeInterval) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw SessionError.denied }
        guard duration >= 15 && duration <= 900 else { throw SessionError.denied }
        let now = Date(), id = UUID().uuidString
        lock.lock()
        activeSession = Session(id: id, started: now,
                                expires: now.addingTimeInterval(duration))
        lock.unlock()
        DispatchQueue.main.async {
            NativeGuidanceOverlay.shared.show(
                message: "RelayOS guidance is active. You can stop it in RelayOS.",
                normalizedX: 0.6, normalizedY: 0.8)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.stop(id: id)
        }
        return ["session_id": id, "expires_at": now.addingTimeInterval(duration).timeIntervalSince1970,
                "status": "active"]
    }

    func status(id: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession, session.id == id, session.expires > Date()
        else { return ["status": "inactive"] }
        return ["status": "active", "session_id": id,
                "expires_at": session.expires.timeIntervalSince1970,
                "last_capture_at": session.lastCapture?.timeIntervalSince1970 as Any? ?? NSNull()]
    }

    func capture(id: String) throws -> [String: Any] {
        lock.lock()
        let isActive = activeSession?.id == id && (activeSession?.expires ?? .distantPast) > Date()
        lock.unlock()
        guard isActive else { throw SessionError.expired }
        let image = try NativeScreenCapture.snapshot()
        lock.lock()
        if activeSession?.id == id { activeSession?.lastCapture = Date() }
        lock.unlock()
        return image
    }

    func stop(id: String) {
        lock.lock()
        let isCurrent = activeSession?.id == id
        if isCurrent { activeSession = nil }
        lock.unlock()
        if isCurrent {
            DispatchQueue.main.async { NativeGuidanceOverlay.shared.clear() }
        }
    }

    func stopAll() {
        lock.lock(); activeSession = nil; lock.unlock()
        DispatchQueue.main.async { NativeGuidanceOverlay.shared.clear() }
    }
}
