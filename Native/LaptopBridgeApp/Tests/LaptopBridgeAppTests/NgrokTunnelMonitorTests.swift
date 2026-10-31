// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NgrokTunnelMonitorTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class NgrokTunnelMonitorTests: XCTestCase {
    private let body = Data("""
        {"tunnels":[{"public_url":"https://example.ngrok-free.dev",
          "config":{"addr":"http://127.0.0.1:8765"}}]}
        """.utf8)

    func testRejectsUnrelatedOrUntrustedInspectorRecords() {
        XCTAssertEqual(NgrokTunnelMonitor.ownedEndpoint(from: body)?.host, "example.ngrok-free.dev")
        for json in [
            #"{"tunnels":[{"public_url":"https://elsewhere.ngrok-free.dev","config":{"addr":"localhost:3000"}}]}"#,
            #"{"tunnels":[{"public_url":"http://example.ngrok-free.dev","config":{"addr":"127.0.0.1:8765"}}]}"#,
            #"{"tunnels":[{"public_url":"https://user:pass@example.ngrok-free.dev","config":{"addr":"127.0.0.1:8765"}}]}"#,
            #"{"tunnels":[{"public_url":"https://example.ngrok-free.dev/evil","config":{"addr":"127.0.0.1:8765"}}]}"#,
            #"{"tunnels":[{"public_url":"https://example.ngrok-free.dev","config":{"addr":"evil.tld:8765"}}]}"#,
        ] {
            XCTAssertNil(NgrokTunnelMonitor.ownedEndpoint(from: Data(json.utf8)))
        }
    }

    func testPublicAuthenticationProofIsNecessary() async {
        let data = body
        let good = NgrokTunnelMonitor { request in
            if request.url?.host == "127.0.0.1" { return (200, data) }
            XCTAssertEqual(request.url?.path, "/mcp")
            return (401, Data())
        }
        let positive = await good.probe()
        XCTAssertEqual(positive.status, .healthy)
        XCTAssertEqual(positive.publicURL?.host, "example.ngrok-free.dev")
        let missing = NgrokTunnelMonitor { req in
            if req.url?.host == "127.0.0.1" { return (200, data) }
            return (404, Data())
        }
        let missingResult = await missing.probe()
        XCTAssertEqual(missingResult.status, .remoteUnavailable)
    }

    func testMissingInspectorDoesNotAdoptEndpoint() async {
        let missing = NgrokTunnelMonitor { _ in (404, Data()) }
        let result = await missing.probe()
        XCTAssertEqual(result.status, .inspectorUnavailable)
        XCTAssertNil(result.publicURL)
    }
}
