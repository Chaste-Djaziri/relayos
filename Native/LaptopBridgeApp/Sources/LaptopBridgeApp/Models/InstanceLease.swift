// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/InstanceLease.swift
import Foundation
import Darwin

/// A macOS advisory lock with stable inode identity. An untrusted symlink or
/// another user's lockfile must never be used for single-instance ownership.
final class InstanceLease {
    private let path: String
    private var descriptor: Int32 = -1

    var isHeld: Bool { descriptor >= 0 }

    init(path: String) { self.path = path }

    func tryAcquire() -> Bool {
        if descriptor >= 0 { return true }
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
