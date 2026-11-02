// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/ScreenSharingSessionTests.swift
import XCTest
@testable import LaptopBridgeApp

final class ScreenSharingSessionTests: XCTestCase {
    func testDecodesBoundedActiveMainDisplaySession() throws {
        let payload = """
        {"active":true,"expires_in_seconds":1799,"scope":"display","target":"main"}
        """
        let status = try JSONDecoder().decode(
            RelayOSScreenSharingStatus.self, from: Data(payload.utf8))
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.expiresInSeconds, 1799)
        XCTAssertEqual(status.scope, "display")
        XCTAssertEqual(status.target, "main")
    }

    @MainActor
    func testSharingSummaryReflectsExpirationAndInactiveState() {
        let model = BridgeModel.preview()
        XCTAssertEqual(model.screenSharingSummary, "Off")
        model.screenSharingActive = true
        model.screenSharingSecondsRemaining = 1800
        XCTAssertEqual(model.screenSharingSummary, "On · 30 min left")
        model.screenSharingSecondsRemaining = 61
        XCTAssertEqual(model.screenSharingSummary, "On · 2 min left")
        model.screenSharingSecondsRemaining = 0
        XCTAssertEqual(model.screenSharingSummary, "Off")
        model.screenSharingActive = false
        XCTAssertEqual(model.screenSharingSummary, "Off")
    }
}
