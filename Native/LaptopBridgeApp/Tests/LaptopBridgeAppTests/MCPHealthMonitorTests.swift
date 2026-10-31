// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/MCPHealthMonitorTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class MCPHealthMonitorTests: XCTestCase {
    private let validBody = Data("""
        {"setup_complete":true,"emergency_stop":false,"pending_approvals":0,
         "active_transport":"ngrok","capabilities":{"project_tools":true}}
        """.utf8)

    func testControlProbeOnlyTrustsAuthenticatedRelayOSStatus() {
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 200, data: validBody), .healthy)
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 401, data: validBody), .unauthorized)
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 403, data: validBody), .unauthorized)
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 200, data: Data("hello".utf8)), .unexpectedService)
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 200, data: Data("{}".utf8)), .unexpectedService)
        XCTAssertEqual(MCPHealthMonitor.evaluate(status: 500, data: validBody), .unexpectedService)
    }

    func testRequestIsLoopbackOnlyAndAuthenticated() {
        let req = MCPHealthMonitor.makeRequest(token: "test-control-token")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8765/control/status")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-relayos-control-token"), "test-control-token")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.timeoutInterval, 2)
    }

    func testProbeHandlesMissingTokenAndConnectionFailure() async {
        let noToken = MCPHealthMonitor(tokenProvider: { nil }, transport: { _ in
            XCTFail("No request should run without a token")
            return (200, self.validBody)
        })
        let result = await noToken.probe()
        XCTAssertEqual(result, .tokenUnavailable)

        struct Offline: Error {}
        let offline = MCPHealthMonitor(tokenProvider: { "long-valid-token-value" }, transport: { _ in
            throw Offline()
        })
        let offlineResult = await offline.probe()
        XCTAssertEqual(offlineResult, .unreachable)
    }

    func testProbeCanAuthenticateResponse() async {
        let body = validBody
        let monitor = MCPHealthMonitor(tokenProvider: { "long-valid-token-value" }, transport: { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return (200, body)
        })
        let result = await monitor.probe()
        XCTAssertEqual(result, .healthy)
    }
}
