// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/RelayOSCursorGuidanceTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class RelayOSCursorGuidanceTests: XCTestCase {
    func testScreenshotTopLeftCoordinatesMapToMacBottomLeftSpace() {
        let display = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        XCTAssertEqual(RelayOSCursorPlacement.point(in: display, x: 0, y: 0),
                       CGPoint(x: -1920, y: 960))
        XCTAssertEqual(RelayOSCursorPlacement.point(in: display, x: 1, y: 1),
                       CGPoint(x: 0, y: -120))
        XCTAssertEqual(RelayOSCursorPlacement.point(in: display, x: 0.5, y: 0.25),
                       CGPoint(x: -960, y: 690))
        XCTAssertNil(RelayOSCursorPlacement.point(in: display, x: -0.1, y: 0.5))
        XCTAssertNil(RelayOSCursorPlacement.point(in: display, x: .nan, y: 0.5))
    }

    func testFixedTargetStandoffDoesNotCoverItemAndClampsToDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 850)
        let marker = RelayOSCursorPlacement.framePointing(
            at: CGPoint(x: 600, y: 425), from: CGPoint(x: 200, y: 425), on: screen
        )
        XCTAssertEqual(marker.midX, 554, accuracy: 0.01)
        XCTAssertEqual(marker.midY, 425, accuracy: 0.01)
        XCTAssertEqual(marker.width, RelayOSCursorPlacement.size.width)
        XCTAssertEqual(marker.height, RelayOSCursorPlacement.size.height)
        let edge = RelayOSCursorPlacement.framePointing(
            at: CGPoint(x: 1199, y: 849), from: CGPoint(x: 1100, y: 800), on: screen)
        XCTAssertLessThanOrEqual(edge.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(edge.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(edge.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(edge.minY, screen.minY)
    }

    func testTipCanRotateTowardAnySideUsingShortestArc() {
        let center = CGPoint(x: 500, y: 500)
        XCTAssertEqual(RelayOSCursorPlacement.rotationToward(
            target: CGPoint(x: 500, y: 600), from: center), 0, accuracy: 0.00001)
        XCTAssertEqual(RelayOSCursorPlacement.rotationToward(
            target: CGPoint(x: 600, y: 500), from: center), .pi / 2, accuracy: 0.00001)
        XCTAssertEqual(RelayOSCursorPlacement.rotationToward(
            target: CGPoint(x: 400, y: 500), from: center), -.pi / 2, accuracy: 0.00001)
        XCTAssertEqual(abs(RelayOSCursorPlacement.rotationToward(
            target: CGPoint(x: 500, y: 400), from: center)), .pi, accuracy: 0.00001)
        var rotation = RelayOSCursorOrientation()
        _ = rotation.advance(toward: Double.pi - 0.1, at: 1)
        let previous = rotation.advance(toward: Double.pi - 0.1, at: 2)
        let next = rotation.advance(toward: -Double.pi + 0.1, at: 2.016)
        XCTAssertLessThan(next - previous, 0.2)
    }

    func testProximityIsApproximateAndRequiresEnteringFromOutside() {
        let target = CGPoint(x: 500, y: 500)
        var gate = RelayOSCursorArrivalGate()
        gate.reset(pointer: CGPoint(x: 510, y: 510), target: target)
        XCTAssertFalse(gate.update(pointer: CGPoint(x: 530, y: 530), target: target))
        XCTAssertFalse(gate.update(pointer: CGPoint(x: 600, y: 500), target: target))
        XCTAssertTrue(gate.update(pointer: CGPoint(x: 500 + RelayOSCursorPlacement.arrivalRadius - 1, y: 500), target: target))
        gate.reset(pointer: CGPoint(x: 700, y: 500), target: target)
        XCTAssertFalse(gate.update(pointer: CGPoint(x: 570, y: 500), target: target))
        XCTAssertTrue(gate.update(pointer: CGPoint(x: 550, y: 500), target: target))
    }

    func testGuidedTravelIsNoticeablySlowerWithoutSlowingNormalFollow() {
        XCTAssertGreaterThan(
            RelayOSCursorMotion.followingFrequency,
            RelayOSCursorMotion.guidingFrequency * 4
        )
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let start = CGRect(x: 120, y: 240, width: 38, height: 38)
        let target = CGRect(x: 920, y: 240, width: 38, height: 38)
        var following = RelayOSCursorMotion()
        var guiding = RelayOSCursorMotion()
        XCTAssertEqual(following.advance(to: start, screen: screen, at: 0), start)
        XCTAssertEqual(guiding.advance(to: start, screen: screen, at: 0), start)
        var normalFrame = start, guidedFrame = start
        for tick in 1...18 {
            let time = Double(tick) / 60.0
            normalFrame = following.advance(
                to: target, screen: screen, at: time)
            guidedFrame = guiding.advance(
                to: target, screen: screen, at: time, guided: true)
        }
        // At 0.3 seconds, ordinary follow has nearly caught up, while
        // the guided marker is still visibly traveling toward the target.
        XCTAssertGreaterThan(normalFrame.minX, guidedFrame.minX + 300)
        XCTAssertGreaterThan(guidedFrame.minX, start.minX)
        XCTAssertLessThan(guidedFrame.minX, target.minX)
        for tick in 19...240 {
            guidedFrame = guiding.advance(
                to: target, screen: screen, at: Double(tick) / 60.0, guided: true)
        }
        XCTAssertEqual(guidedFrame.minX, target.minX, accuracy: 0.25)
    }

    func testSwitchingFromFollowToGuidanceKeepsPositionContinuous() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        var motion = RelayOSCursorMotion()
        let start = CGRect(x: 200, y: 240, width: 38, height: 38)
        let elsewhere = CGRect(x: 1100, y: 240, width: 38, height: 38)
        _ = motion.advance(to: start, screen: screen, at: 0)
        let moving = motion.advance(to: elsewhere, screen: screen, at: 0.0167)
        let switched = motion.advance(
            to: start, screen: screen, at: 0.0334, guided: true)
        // A mode switch does not teleport the marker or carry excessive
        // velocity from the fast passive follow spring.
        XCTAssertLessThan(abs(switched.minX - moving.minX), 5)
    }

    func testTargetHoldsWhileMouseIsFarAndReturnsAfterTimeout() throws {
        let payload = """
        {"active":true,"id":"target-a","display":"main","x":0.8,"y":0.4,"expires_at":2000}
        """
        let cmd = try JSONDecoder().decode(RelayOSPointerGuidance.self, from: Data(payload.utf8))
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = try XCTUnwrap(cmd.point(in: screen, now: 1900))
        var gate = RelayOSCursorArrivalGate()
        gate.reset(pointer: CGPoint(x: 100, y: 100), target: target)
        XCTAssertFalse(gate.update(pointer: CGPoint(x: 300, y: 300), target: target))
        XCTAssertNotNil(cmd.point(in: screen, now: 1999))
        XCTAssertNil(cmd.point(in: screen, now: 2000))
        XCTAssertTrue(gate.update(pointer: target, target: target))
    }
}
