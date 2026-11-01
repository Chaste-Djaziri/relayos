// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ManagedProcessSlot.swift
import Foundation

/// Keeps asynchronous termination callbacks from discarding a newer child process.
@MainActor
final class ManagedProcessSlot {
    private(set) var process: Process?

    func assign(_ process: Process?) {
        self.process = process
    }

    @discardableResult
    func clearIfMatches(_ terminated: Process) -> Bool {
        guard process === terminated else { return false }
        process = nil
        return true
    }
}
