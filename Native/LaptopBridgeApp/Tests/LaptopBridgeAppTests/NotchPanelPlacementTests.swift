// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NotchPanelPlacementTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class NotchPanelPlacementTests: XCTestCase {
    func testPhysicalNotchStaysCompletelyUncovered() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let layout = NotchPanelPlacement.layout(
            displayFrame: screen, visibleFrame: visible, hardwareNotchWidth: 185)
        XCTAssertTrue(layout.hasHardwareNotch)
        XCTAssertEqual(layout.frame.width, 568)
        XCTAssertEqual(layout.frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(layout.centerGap, 185 + 20)
        XCTAssertEqual(layout.leftWidth + layout.centerGap + layout.rightWidth,
                       layout.frame.width, accuracy: 0.01)
        XCTAssertEqual(layout.topBandHeight, 38)
        XCTAssertEqual(layout.frame.height,
                       layout.topBandHeight + NotchPanelPlacement.trayHeight)
        // The lower tray begins exactly below the camera/menu-bar strip.
        XCTAssertEqual(layout.frame.minY + NotchPanelPlacement.trayHeight,
                       visible.maxY, accuracy: 0.01)
    }

    func testLargerCameraHousingGetsLargerTransparentGap() {
        let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let visible = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let layout = NotchPanelPlacement.layout(
            displayFrame: screen, visibleFrame: visible, hardwareNotchWidth: 220)
        XCTAssertGreaterThanOrEqual(layout.centerGap, 244)
        XCTAssertEqual(layout.frame.midX, screen.midX, accuracy: 0.01)
        XCTAssertGreaterThan(layout.leftWidth, 0)
        XCTAssertGreaterThan(layout.rightWidth, 0)
    }

    func testExternalMonitorWithoutNotchStaysBelowMenuBar() {
        let display = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -120, width: 1920, height: 1040)
        let layout = NotchPanelPlacement.layout(
            displayFrame: display, visibleFrame: visible)
        XCTAssertFalse(layout.hasHardwareNotch)
        XCTAssertEqual(layout.frame.midX, visible.midX, accuracy: 0.01)
        XCTAssertLessThan(layout.frame.maxY, visible.maxY)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, visible.minX)
    }

    func testCompactDisplayClampsWidthAndKeepsBothEars() {
        let display = CGRect(x: 50, y: 100, width: 330, height: 300)
        let visible = CGRect(x: 50, y: 100, width: 330, height: 262)
        let layout = NotchPanelPlacement.layout(
            displayFrame: display, visibleFrame: visible, hardwareNotchWidth: 90)
        XCTAssertLessThanOrEqual(layout.frame.width, visible.width - 24)
        XCTAssertEqual(layout.frame.minX, visible.midX - layout.frame.width / 2)
        XCTAssertGreaterThan(layout.leftWidth, 0)
        XCTAssertGreaterThan(layout.rightWidth, 0)
        XCTAssertEqual(layout.centerGap + layout.leftWidth + layout.rightWidth,
                       layout.frame.width, accuracy: 0.01)
    }
}
