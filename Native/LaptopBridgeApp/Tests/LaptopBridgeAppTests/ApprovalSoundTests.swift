// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/ApprovalSoundTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class ApprovalSoundTests: XCTestCase {
    func testDefaultsToEnabledAndRespectsPreference() throws {
        let identifier = "RelayOSApprovalSoundTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        XCTAssertTrue(ApprovalSound.isEnabled(in: defaults))
        defaults.set(false, forKey: ApprovalSound.preferenceKey)
        XCTAssertFalse(ApprovalSound.isEnabled(in: defaults))
        defaults.set(true, forKey: ApprovalSound.preferenceKey)
        XCTAssertTrue(ApprovalSound.isEnabled(in: defaults))
    }
}
