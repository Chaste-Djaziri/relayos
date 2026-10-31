// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/InstanceLeaseTests.swift
import Foundation
import XCTest
import Darwin
@testable import LaptopBridgeApp

final class InstanceLeaseTests: XCTestCase {
    func testSecondInstanceCannotTakeLockUntilFirstReleases() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("relayos-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = InstanceLease(path: path)
        let second = InstanceLease(path: path)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertTrue(first.isHeld)
        XCTAssertFalse(second.tryAcquire())
        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertTrue(second.tryAcquire())
        second.release()
        XCTAssertTrue(first.tryAcquire())
        first.release()
    }

    func testRefusesSymlinkAndWorldReadableLocks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayos-lock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real.lock")
        let link = root.appendingPathComponent("link.lock")
        XCTAssertTrue(InstanceLease(path: target.path).tryAcquire())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(InstanceLease(path: link.path).tryAcquire())
        XCTAssertEqual(chmod(target.path, mode_t(0o644)), 0)
        XCTAssertFalse(InstanceLease(path: target.path).tryAcquire())
    }
}
