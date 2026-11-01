// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NotchPanelPlacementTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class NotchPanelPlacementTests: XCTestCase {
    func testTopCenterPlacementStaysBelowMenuBar() {
        let visible = CGRect(x: 0, y: 24, width: 1512, height: 890)
        let frame = NotchPanelPlacement.frame(in: visible)
        XCTAssertEqual(frame.width, 432)
        XCTAssertEqual(frame.height, 392)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, visible.maxY - 10, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
    }

    func testExternalMonitorWithNegativeCoordinates() {
        let visible = CGRect(x: -1920, y: -120, width: 1920, height: 1040)
        let frame = NotchPanelPlacement.frame(in: visible)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.01)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
    }

    func testSmallDisplayClampsPanelInsideUsableFrame() {
        let visible = CGRect(x: 50, y: 150, width: 320, height: 270)
        let frame = NotchPanelPlacement.frame(in: visible)
        XCTAssertLessThanOrEqual(frame.width, visible.width - 24)
        XCTAssertLessThanOrEqual(frame.height, visible.height - 24)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
    }
}
