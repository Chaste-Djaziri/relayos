// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalSound.swift
import AppKit
import Foundation

enum ApprovalSound {
    static let preferenceKey = "relayos.approvalSoundEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// Play once when a *new* request is presented, not on every polling tick.
    @MainActor
    static func playIfEnabled() {
        guard isEnabled() else { return }
        let sound = NSSound(named: NSSound.Name("Glass"))
            ?? NSSound(named: NSSound.Name("Ping"))
        sound?.play()
    }
}
