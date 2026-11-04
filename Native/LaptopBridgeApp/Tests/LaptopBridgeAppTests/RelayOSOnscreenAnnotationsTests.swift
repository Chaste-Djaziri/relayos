// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/RelayOSOnscreenAnnotationsTests.swift
import AppKit
import CoreGraphics
import XCTest
@testable import LaptopBridgeApp

final class RelayOSOnscreenAnnotationsTests: XCTestCase {
    private func item(_ kind: String, x: Double = 0.2, y: Double = 0.3,
                      w: Double = 0.2, h: Double = 0.4,
                      display: String = "main", onlyApp: String? = nil) -> RelayOSScreenInk {
        RelayOSScreenInk(
            id: "item-1", kind: kind, display: display,
            x: x, y: y, w: w, h: h,
            color: "accent", stroke_width: 3,
            opacity: 1, expires_at: 5000,
            text: nil, font_size: nil, points: nil,
            only_when_app: onlyApp)
    }

    func testLabelJSONDecodingUsesFullDisplayTopLeftCoordinates() throws {
        let payload = """
        {"active":true,"revision":4,"annotations":[
          {"id":"label1","display":"main","kind":"label","x":0.1,"y":0.2,
           "w":0.25,"h":0.0,"text":"Front wheel","font_size":18,
           "color":"yellow","stroke_width":3,"opacity":1,
           "expires_at":5000},
          {"id":"point1","display":"main","kind":"arrow","x":0.3,"y":0.45,
           "w":-0.15,"h":0.3,"color":"red","stroke_width":4,"opacity":1,
           "expires_at":5000}
        ]}
        """
        let snapshot = try JSONDecoder().decode(
            RelayOSScreenInkSnapshot.self, from: Data(payload.utf8))
        XCTAssertTrue(snapshot.active)
        XCTAssertEqual(snapshot.annotations.count, 2)
        XCTAssertEqual(snapshot.annotations[0].text, "Front wheel")
        let arrow = snapshot.annotations[1]
        XCTAssertEqual(arrow.w, -0.15, accuracy: 0.0001)
        let path = RelayOSInkGeometry.drawPath(
            for: arrow, in: CGSize(width: 1000, height: 800))
        XCTAssertFalse(path.isEmpty)
        XCTAssertLessThanOrEqual(path.boundingRect.minX, 300)
        XCTAssertGreaterThanOrEqual(path.boundingRect.maxY, 600)
    }

    func testEllipseAndScribbleDrawOnNativeDisplayCanvas() {
        let size = CGSize(width: 1000, height: 600)
        let oval = item("ellipse", x: 0.2, y: 0.3, w: 0.15, h: 0.2)
        let ovalPath = RelayOSInkGeometry.drawPath(for: oval, in: size)
        XCTAssertEqual(ovalPath.boundingRect.minX, 200, accuracy: 0.1)
        XCTAssertEqual(ovalPath.boundingRect.minY, 180, accuracy: 0.1)
        XCTAssertEqual(ovalPath.boundingRect.width, 150, accuracy: 0.1)
        XCTAssertEqual(ovalPath.boundingRect.height, 120, accuracy: 0.1)

        var scribble = item("scribble")
        // Decoder-driven path tests avoid mutating immutable screen annotations.
        let json = """
        {"id":"ink","display":"main","kind":"scribble","x":0,"y":0,
         "w":0,"h":0,"points":[[0.1,0.1],[0.4,0.3],[0.7,0.2]],
         "color":"blue","stroke_width":3,"opacity":1,"expires_at":5000}
        """
        scribble = try! JSONDecoder().decode(RelayOSScreenInk.self, from: Data(json.utf8))
        let path = RelayOSInkGeometry.drawPath(for: scribble, in: size)
        XCTAssertEqual(path.boundingRect.minX, 100, accuracy: 0.1)
        XCTAssertEqual(path.boundingRect.maxX, 700, accuracy: 0.1)
    }

    func testAppScopedDrawingsAreHiddenOnAppSwitchOrExpiry() {
        let item = item("label", display: "main", onlyApp: "com.microsoft.VSCode")
        XCTAssertTrue(item.active(for: CGMainDisplayID(),
                                  frontmost: "com.microsoft.VSCode", now: 100))
        XCTAssertFalse(item.active(for: CGMainDisplayID(),
                                   frontmost: "com.apple.finder", now: 100))
        XCTAssertFalse(item.active(for: CGMainDisplayID(),
                                   frontmost: "com.microsoft.VSCode", now: 5001))
        XCTAssertFalse(item.active(for: CGMainDisplayID() + 1,
                                   frontmost: "com.microsoft.VSCode", now: 100))
    }
}
