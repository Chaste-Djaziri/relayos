// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/RelayOSCursorTipTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class RelayOSCursorTipTests: XCTestCase {
    func testTypwriterRevealsGraphemeClustersWithoutBreakingEmoji() {
        let message = "Hello 👩🏽‍💻!"
        XCTAssertEqual(RelayOSCursorTipAnimation.displayedText(message, elapsed: 0), "")
        XCTAssertEqual(RelayOSCursorTipAnimation.displayedText(
            message, elapsed: 6.0 / 32.0), "Hello ")
        XCTAssertEqual(RelayOSCursorTipAnimation.displayedText(
            message, elapsed: 7.0 / 32.0), "Hello 👩🏽‍💻")
        XCTAssertEqual(RelayOSCursorTipAnimation.displayedText(
            message, elapsed: 100), message)
        XCTAssertEqual(RelayOSCursorTipAnimation.characterCount(elapsed: -0.3, total: 10), 0)
        XCTAssertEqual(RelayOSCursorTipAnimation.characterCount(elapsed: .infinity, total: 10), 0)
    }

    func testBubblePlacementStaysOnScreenAndFlipsAtRightEdge() {
        let display = CGRect(x: -1512, y: -85, width: 1512, height: 982)
        let centerCursor = CGRect(x: -900, y: 450, width: 38, height: 38)
        let center = RelayOSCursorTipPlacement.frame(near: centerCursor, screen: display)
        XCTAssertGreaterThan(center.minX, centerCursor.maxX)
        let rightCursor = CGRect(x: -60, y: 500, width: 38, height: 38)
        let right = RelayOSCursorTipPlacement.frame(near: rightCursor, screen: display)
        XCTAssertLessThan(right.maxX, rightCursor.minX)
        for cursor in [
            CGRect(x: -1500, y: -80, width: 38, height: 38),
            CGRect(x: -60, y: 850, width: 38, height: 38),
            CGRect(x: -800, y: 70, width: 38, height: 38),
        ] {
            let bubble = RelayOSCursorTipPlacement.frame(near: cursor, screen: display)
            XCTAssertGreaterThanOrEqual(bubble.minX, display.minX)
            XCTAssertGreaterThanOrEqual(bubble.minY, display.minY)
            XCTAssertLessThanOrEqual(bubble.maxX, display.maxX)
            XCTAssertLessThanOrEqual(bubble.maxY, display.maxY)
        }
    }

    func testTipModelDecodesAndExpires() throws {
        let payload = """
        {"id":"tip-001","text":"Check the settings icon.",
        "expires_at":2000,"target_id":"pointer-123"}
        """
        let tip = try JSONDecoder().decode(
            RelayOSCursorTip.self, from: Data(payload.utf8))
        XCTAssertTrue(tip.isValid(at: Date(timeIntervalSince1970: 1900)))
        XCTAssertFalse(tip.isValid(at: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(tip.targetID, "pointer-123")
    }

    func testStandaloneTipDecodedWithoutActiveTarget() throws {
        let payload = """
        {"active":false,"tip":{"id":"t1","text":"Try this button",
        "expires_at":2000,"target_id":null}}
        """
        let command = try JSONDecoder().decode(
            RelayOSPointerGuidance.self, from: Data(payload.utf8))
        XCTAssertFalse(command.active)
        XCTAssertNil(command.id)
        XCTAssertEqual(command.tip?.text, "Try this button")
    }
}
