// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/RelayOSScreenHighlightTests.swift
import AppKit
import XCTest
@testable import LaptopBridgeApp

final class RelayOSScreenHighlightTests: XCTestCase {
    private func region(_ shape: String, bounds: [Double],
                        points: [[Double]] = [], closed: Bool = true) -> RelayOSHighlightSpec {
        RelayOSHighlightSpec(shape: shape, bounds: bounds, points: points,
                             closed: closed, cornerRadius: 8,
                             fillOpacity: 0.12, strokeWidth: 2.5)
    }

    func testRectanglePathStartsAtUpperLeftAndCoversFullBounds() {
        let rectangle = region("rect", bounds: [0.1, 0.2, 0.3, 0.4])
        XCTAssertTrue(rectangle.isValid)
        let path = RelayOSHighlightGeometry.path(
            for: rectangle, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(path.boundingRect, CGRect(x: 100, y: 160, width: 300, height: 320))
        XCTAssertTrue(path.contains(CGPoint(x: 250, y: 300)))
        XCTAssertFalse(path.contains(CGPoint(x: 450, y: 300)))
        var first: CGPoint?
        path.forEach { element in
            if first == nil, case .move(to: let point) = element { first = point }
        }
        XCTAssertEqual(first, CGPoint(x: 100, y: 160))
    }

    func testRoundedRectAndEllipsePathsRespectBounds() {
        let size = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for shape in ["rounded_rect", "ellipse"] {
            let spec = region(shape, bounds: [0.1, 0.2, 0.3, 0.4])
            XCTAssertTrue(spec.isValid)
            let path = RelayOSHighlightGeometry.path(for: spec, in: size)
            XCTAssertEqual(path.boundingRect.minX, 100, accuracy: 0.1)
            XCTAssertEqual(path.boundingRect.minY, 160, accuracy: 0.1)
            XCTAssertTrue(path.contains(CGPoint(x: 250, y: 320)))
            XCTAssertFalse(path.contains(CGPoint(x: 90, y: 320)))
        }
    }

    func testOpenFreeformAndPolygonCanTraceIrregularElements() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let pts = [[0.1,0.1],[0.8,0.15],[0.6,0.6],[0.2,0.75]]
        let polygon = region("polygon", bounds: [0.1,0.1,0.7,0.65], points: pts)
        XCTAssertTrue(polygon.isValid)
        XCTAssertTrue(RelayOSHighlightGeometry.path(for: polygon, in: rect)
            .contains(CGPoint(x: 400, y: 250)))
        let open = region("path", bounds: [0.1,0.1,0.7,0.65], points: pts, closed: false)
        XCTAssertTrue(open.isValid)
        XCTAssertFalse(open.hasFill)
        let freeform = RelayOSHighlightGeometry.path(for: open, in: rect)
        XCTAssertFalse(freeform.isEmpty)
        XCTAssertTrue(RelayOSHighlightGeometry.isNear(
            pointer: CGPoint(x: 450, y: 800 - 106),
            region: open, screen: rect, radius: 35))
    }

    func testMouseProximityIncludesRegionInteriorAndOutlineMargin() {
        let display = CGRect(x: -1200, y: -100, width: 1200, height: 800)
        let spec = region("rect", bounds: [0.1, 0.2, 0.2, 0.1])
        let pointInside = CGPoint(x: -1020, y: display.maxY - 200)
        XCTAssertTrue(RelayOSHighlightGeometry.isNear(
            pointer: pointInside, region: spec, screen: display, radius: 48))
        let pointNear = CGPoint(x: -1085, y: display.maxY - 200)
        XCTAssertTrue(RelayOSHighlightGeometry.isNear(
            pointer: pointNear, region: spec, screen: display, radius: 48))
        let far = CGPoint(x: -650, y: display.maxY - 500)
        XCTAssertFalse(RelayOSHighlightGeometry.isNear(
            pointer: far, region: spec, screen: display, radius: 48))
    }

    func testInvalidSpecFailsClosed() {
        let invalid = region("polygon", bounds: [0.1,0.1,0.2,0.3], points: [[0,0],[1,1]])
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(RelayOSHighlightGeometry.path(for: invalid,
            in: CGRect(x: 0, y: 0, width: 800, height: 500)).isEmpty)
        let out = region("rect", bounds: [0.9,0.1,0.5,0.5])
        XCTAssertFalse(out.isValid)
    }

    func testOutlineIsSlowerThanPreviousAnimationAndFillFollowsStroke() {
        XCTAssertGreaterThanOrEqual(RelayOSHighlightTiming.strokeDuration, 1.8)
        XCTAssertGreaterThan(RelayOSHighlightTiming.strokeDelay, 0)
        XCTAssertGreaterThanOrEqual(
            RelayOSHighlightTiming.fillDelay,
            RelayOSHighlightTiming.strokeDelay + RelayOSHighlightTiming.strokeDuration
        )
        XCTAssertGreaterThan(RelayOSHighlightTiming.fillDuration, 0)
        XCTAssertGreaterThan(RelayOSHighlightTiming.dismissDuration, 0)
    }

    func testGuidanceJSONIncludesOptionalRegionAndExistingCursorRemainsCompatible() throws {
        let payload = """
        {"active":true,"id":"r1","display":"main","x":0.25,"y":0.3,
        "expires_at":2000,"show_cursor":false,"proximity_radius":30,
        "region":{"shape":"rounded_rect","bounds":[0.1,0.2,0.3,0.2],
        "points":[],"closed":true,"corner_radius":10,
        "fill_opacity":0.12,"stroke_width":2.5}}
        """
        let new = try JSONDecoder().decode(RelayOSPointerGuidance.self, from: Data(payload.utf8))
        XCTAssertTrue(new.region?.isValid == true)
        XCTAssertEqual(new.region?.center.x ?? 0, 0.25, accuracy: 0.000001)
        XCTAssertEqual(new.region?.center.y ?? 0, 0.3, accuracy: 0.000001)
        XCTAssertEqual(new.showCursor, false)
        XCTAssertEqual(new.proximityRadius, 30)
        let original = """
        {"active":true,"id":"old","display":"main","x":0.1,"y":0.2,"expires_at":2000}
        """
        let old = try JSONDecoder().decode(RelayOSPointerGuidance.self, from: Data(original.utf8))
        XCTAssertNil(old.region)
        XCTAssertNil(old.showCursor)
    }
}
