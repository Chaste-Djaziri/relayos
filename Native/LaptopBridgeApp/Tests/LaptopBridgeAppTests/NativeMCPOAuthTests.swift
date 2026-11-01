// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NativeMCPOAuthTests.swift
import XCTest
import CryptoKit
@testable import LaptopBridgeApp

final class NativeMCPOAuthTests: XCTestCase {
    var dir: URL!
    var store: NativeMCPDevelopmentStore!
    var auth: NativeMCPOAuth!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = NativeMCPDevelopmentStore(directory: dir, port: 18765)
        _ = try store.bootstrap()
        auth = NativeMCPOAuth(store: store)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func s256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testLocalPKCEOAuthApprovalTokenRefreshAndRevocation() throws {
        let redirect = "http://127.0.0.1:8543/callback"
        let client = try auth.register(["client_name": "XCTest native MCP",
                                        "redirect_uris": [redirect]])
        let clientID = try XCTUnwrap(client["client_id"] as? String)
        let verifier = String(repeating: "a", count: 48)
        let requestID = try auth.authorize([
            "client_id": clientID, "redirect_uri": redirect,
            "response_type": "code", "code_challenge_method": "S256",
            "code_challenge": s256(verifier),
            "scope": "mcp", "state": "opaque123", "resource": store.endpoint
        ])
        switch try auth.approvalStatus(requestID) {
        case .pending: break
        default: XCTFail("Must be pending before in-person approval")
        }
        try auth.approvals.decide(id: requestID, decision: .once)
        let callback: URL
        switch try auth.approvalStatus(requestID) {
        case .redirect(let url): callback = url
        default: throw NativeMCPOAuth.OAuthError.invalidGrant
        }
        let callbackParts = try XCTUnwrap(URLComponents(url: callback, resolvingAgainstBaseURL: false))
        let code = try XCTUnwrap(callbackParts.queryItems?.first(where: { $0.name == "code" })?.value)
        XCTAssertEqual(callbackParts.queryItems?.first(where: { $0.name == "state" })?.value, "opaque123")
        if case .denied = try auth.approvalStatus(requestID) { } else { XCTFail("Callback code must be one-time") }

        let parameters = ["grant_type": "authorization_code", "client_id": clientID,
                          "redirect_uri": redirect, "code": code, "code_verifier": verifier]
        let issued = try auth.token(parameters)
        let access = try XCTUnwrap(issued["access_token"] as? String)
        let refresh = try XCTUnwrap(issued["refresh_token"] as? String)
        let verifierStore = NativeMCPAuthorization(databaseURL: store.databaseURL)
        XCTAssertTrue(verifierStore.validateAccessToken(access, resource: store.endpoint))
        XCTAssertThrowsError(try auth.token(parameters))
        let renewed = try auth.token(["grant_type": "refresh_token",
                                       "client_id": clientID, "refresh_token": refresh])
        let nextAccess = try XCTUnwrap(renewed["access_token"] as? String)
        XCTAssertFalse(verifierStore.validateAccessToken(access, resource: store.endpoint))
        XCTAssertTrue(verifierStore.validateAccessToken(nextAccess, resource: store.endpoint))
        XCTAssertThrowsError(try auth.token(["grant_type": "refresh_token",
                                              "client_id": clientID, "refresh_token": refresh]))
        try auth.revoke(token: nextAccess, clientID: clientID)
        XCTAssertFalse(verifierStore.validateAccessToken(nextAccess, resource: store.endpoint))
    }

    func testInvalidRedirectAndPKCEAreRejected() throws {
        XCTAssertThrowsError(try auth.register([
            "client_name": "Invalid", "redirect_uris": ["https://malicious.example/callback"]
        ]))
        let registered = try auth.register([
            "client_name": "Local", "redirect_uris": ["http://localhost:9000/callback"]
        ])
        let id = try XCTUnwrap(registered["client_id"] as? String)
        XCTAssertThrowsError(try auth.authorize([
            "client_id": id, "redirect_uri": "http://127.0.0.1:9000/callback",
            "response_type": "code", "code_challenge_method": "S256",
            "code_challenge": String(repeating: "a", count: 43),
            "state": "n"
        ]))
        XCTAssertThrowsError(try auth.authorize([
            "client_id": id, "redirect_uri": "http://localhost:9000/callback",
            "response_type": "code", "code_challenge_method": "plain",
            "code_challenge": String(repeating: "a", count: 43),
            "state": "n"
        ]))
    }

    func testHTTPDiscoveryAndRegistration() throws {
        let broker = NativeMCPHTTP(authorization: .init(databaseURL: store.databaseURL),
                                   port: 18765, oauth: auth)
        let headers = ["host": "127.0.0.1:18765"]
        let metadata = broker.handle(method: "GET", path: "/.well-known/oauth-authorization-server",
                                     headers: headers, body: Data())
        XCTAssertEqual(metadata.status, 200)
        XCTAssertTrue(String(decoding: metadata.body, as: UTF8.self).contains("/token"))
        let data = try JSONSerialization.data(withJSONObject: [
            "client_name": "Local agent", "redirect_uris": ["http://localhost:9876/complete"]
        ])
        let registration = broker.handle(method: "POST", path: "/register",
                                         headers: headers, body: data)
        XCTAssertEqual(registration.status, 201)
        XCTAssertTrue(String(decoding: registration.body, as: UTF8.self).contains("client_id"))
    }
}
