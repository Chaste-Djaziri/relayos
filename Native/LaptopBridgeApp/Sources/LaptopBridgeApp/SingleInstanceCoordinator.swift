// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/SingleInstanceCoordinator.swift
import AppKit
import Darwin
import Foundation

/// One foreground RelayOS owner per macOS user. No unrelated processes are killed.
@MainActor
final class SingleInstanceCoordinator {
    static let shared = SingleInstanceCoordinator()
    private let takeoverName = Notification.Name("rw.shangazi.relayos.requestTakeover")
    private let lockPath = "/tmp/rw.shangazi.relayos.\(getuid()).lock"
    private var lockFD: Int32 = -1
    private var observer: NSObjectProtocol?

    private init() {}

    func claimOrReplaceExistingInstance() -> Bool {
        // Never unlink the file: two apps could otherwise lock different inodes.
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            installTakeoverObserver()
            if !retireLegacyAppInstances() { release(); return false }
            return true
        }

        // Ask the previous instance to terminate gracefully, then wait until
        // it releases the lock. Do not kill a process based on its name/PID.
        DistributedNotificationCenter.default().postNotificationName(
            takeoverName, object: nil, userInfo: nil, deliverImmediately: true
        )
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFD = fd
                installTakeoverObserver()
                if !retireLegacyAppInstances() { release(); return false }
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        close(fd)
        return false
    }

    /// Older releases did not implement the shared lock. Identify only the
    /// RelayOS app bundle; never terminate by executable name or port.
    private func retireLegacyAppInstances() -> Bool {
        let others = NSWorkspace.shared.runningApplications.filter { candidate in
            candidate.processIdentifier != getpid()
                && candidate.bundleIdentifier == "rw.shangazi.relayos"
        }
        for app in others {
            guard app.terminate() else { return false }
        }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return others.allSatisfy(\.isTerminated)
    }

    private func installTakeoverObserver() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: takeoverName, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                BridgeModel.shared.shutdownServices()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func release() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }
}
