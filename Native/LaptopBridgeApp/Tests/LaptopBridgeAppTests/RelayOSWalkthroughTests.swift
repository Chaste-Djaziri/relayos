// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/RelayOSWalkthroughTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class RelayOSWalkthroughTests: XCTestCase {
    func testOnlyActiveSupportedAppIsObserved() throws {
        let payload = """
        {"id":"test-123","flow":"system_settings_general","status":"active",
        "active":true,"step":0,"total_steps":2,
        "instruction":"Open System Settings","attention_needed":false,
        "expires_in_seconds":300}
        """
        let status = try JSONDecoder().decode(
            RelayOSWalkthroughStatus.self, from: Data(payload.utf8))
        let visible = RelayOSGeneralObservation(
            frontmostBundleID: "com.apple.systempreferences",
            accessibility: true, generalSelected: false, generalBounds: nil)
        XCTAssertTrue(RelayOSWalkthroughRules.shouldReport(status: status, observation: visible))
        let unrelated = RelayOSGeneralObservation(
            frontmostBundleID: "com.openai.chat", accessibility: false,
            generalSelected: false, generalBounds: nil)
        XCTAssertTrue(RelayOSWalkthroughRules.shouldReport(status: status, observation: unrelated))
        let completed = try JSONDecoder().decode(
            RelayOSWalkthroughStatus.self,
            from: Data(payload.replacingOccurrences(of: "\"status\":\"active\"", with: "\"status\":\"completed\"")
                .replacingOccurrences(of: "\"step\":0", with: "\"step\":2").utf8))
        XCTAssertFalse(RelayOSWalkthroughRules.shouldReport(status: completed, observation: visible))
    }

    func testNativeTipAndTargetAreReadOnlyMetadata() {
        let observation = RelayOSGeneralObservation(
            frontmostBundleID: "com.apple.systempreferences",
            accessibility: true, generalSelected: false, generalBounds: [0.1, 0.2, 0.15, 0.04])
        XCTAssertTrue(observation.isSystemSettingsFrontmost)
        XCTAssertEqual(observation.generalBounds?.count, 4)
    }
}
