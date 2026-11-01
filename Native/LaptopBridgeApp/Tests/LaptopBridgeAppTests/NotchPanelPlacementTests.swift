// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NotchPanelPlacementTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class NotchPanelPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    private func notch(_ phase: NotchPanelPhase) -> NotchPanelPlacement.Layout {
        NotchPanelPlacement.layout(displayFrame: screen, visibleFrame: visible,
                                   hardwareNotchWidth: 185, phase: phase)
    }

    func testCollapsedIsOneBlackTopBandWithCameraGapReserved() {
        let layout = notch(.collapsed)
        XCTAssertTrue(layout.hasHardwareNotch)
        XCTAssertEqual(layout.frame.height, layout.topBandHeight)
        XCTAssertEqual(layout.frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(layout.topBandHeight, 38)
        XCTAssertGreaterThanOrEqual(layout.centerGap, 185 + 18)
        XCTAssertEqual(layout.leftWidth + layout.centerGap + layout.rightWidth,
                       layout.frame.width, accuracy: 0.01)
    }

    func testHoverPeekEnlargesSlightlyWithoutFullTray() {
        let collapsed = notch(.collapsed)
        let hover = notch(.hovered)
        let expanded = notch(.expanded)
        XCTAssertGreaterThan(hover.frame.width, collapsed.frame.width)
        XCTAssertLessThan(hover.frame.width, expanded.frame.width)
        XCTAssertEqual(hover.frame.height, hover.topBandHeight + 28)
        XCTAssertLessThan(hover.frame.height, expanded.frame.height)
        XCTAssertEqual(hover.frame.maxY, collapsed.frame.maxY, accuracy: 0.01)
        XCTAssertEqual(hover.centerGap, collapsed.centerGap, accuracy: 0.01)
    }

    func testClickExpandsDownwardAndLeavingReturnsToCompactGeometry() {
        let collapsed = notch(.collapsed)
        let expanded = notch(.expanded)
        XCTAssertEqual(expanded.frame.height, expanded.topBandHeight + 94)
        XCTAssertEqual(expanded.frame.maxY, collapsed.frame.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(expanded.frame.width, collapsed.frame.width)
        XCTAssertEqual(expanded.leftWidth + expanded.centerGap + expanded.rightWidth,
                       expanded.frame.width, accuracy: 0.01)
        XCTAssertEqual(notch(.collapsed).frame, collapsed.frame)
    }

    func testLargerHousingKeepsAdditionalBlackExclusion() {
        let monitor = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let usable = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor, visibleFrame: usable,
                hardwareNotchWidth: 220, phase: phase)
            XCTAssertGreaterThanOrEqual(layout.centerGap, 238)
            XCTAssertEqual(layout.frame.midX, usable.midX, accuracy: 0.01)
            XCTAssertGreaterThan(layout.leftWidth, 0)
            XCTAssertGreaterThan(layout.rightWidth, 0)
        }
    }

    func testExternalDisplayAlwaysStaysBelowMenuBar() {
        let monitor = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let usable = CGRect(x: -1920, y: -120, width: 1920, height: 1040)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor, visibleFrame: usable, phase: phase)
            XCTAssertFalse(layout.hasHardwareNotch)
            XCTAssertEqual(layout.frame.midX, usable.midX, accuracy: 0.01)
            XCTAssertLessThan(layout.frame.maxY, usable.maxY)
        }
    }

    func testNarrowDisplayKeepsBothEarsAndClampsWidth() {
        let monitor = CGRect(x: 50, y: 100, width: 330, height: 300)
        let usable = CGRect(x: 50, y: 100, width: 330, height: 262)
        for phase in NotchPanelPhase.allCases {
            let layout = NotchPanelPlacement.layout(
                displayFrame: monitor, visibleFrame: usable,
                hardwareNotchWidth: 90, phase: phase)
            XCTAssertLessThanOrEqual(layout.frame.width, usable.width - 24)
            XCTAssertGreaterThan(layout.leftWidth, 0)
            XCTAssertGreaterThan(layout.rightWidth, 0)
            XCTAssertEqual(layout.leftWidth + layout.centerGap + layout.rightWidth,
                           layout.frame.width, accuracy: 0.01)
        }
    }
}
