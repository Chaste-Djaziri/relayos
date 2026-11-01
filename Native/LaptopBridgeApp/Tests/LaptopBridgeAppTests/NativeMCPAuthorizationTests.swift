// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/NativeMCPAuthorizationTests.swift
import XCTest
import SQLite3
import CryptoKit
@testable import LaptopBridgeApp

final class NativeMCPAuthorizationTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("state.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in [
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE oauth_tokens (token_digest TEXT, token_type TEXT, expires_at REAL, revoked_at REAL, resource TEXT)",
            "CREATE TABLE project_sessions (token TEXT, root TEXT, status TEXT, expires_at REAL, revoked_at REAL)",
            "CREATE TABLE permission_grants (grant_type TEXT, scope TEXT, revoked_at REAL, expires_at REAL)"
        ] { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func execute(_ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testMissingDataDeniesTokensAndSessions() {
        let auth = NativeMCPAuthorization(databaseURL: databaseURL)
        XCTAssertFalse(auth.validateAccessToken("missing"))
        XCTAssertFalse(auth.isProjectSessionActive("missing", root: directory))
        XCTAssertFalse(auth.isFolderAuthorized(directory))
    }

    func testUnexpiredOAuthTokenAndResourceAreRequired() {
        let digest = SHA256.hash(data: Data("secret-access".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', \(future), NULL, 'https://agent.example/mcp')")
        let auth = NativeMCPAuthorization(databaseURL: databaseURL)
        XCTAssertTrue(auth.validateAccessToken("secret-access", resource: "https://agent.example/mcp"))
        XCTAssertFalse(auth.validateAccessToken("other-access"))
        XCTAssertFalse(auth.validateAccessToken("secret-access", resource: "https://wrong.example/mcp"))
        execute("UPDATE oauth_tokens SET revoked_at = 1")
        XCTAssertFalse(auth.validateAccessToken("secret-access"))
    }

    func testEmergencyStopOverridesApprovedAccess() {
        let digest = SHA256.hash(data: Data("secret-access".utf8))
            .map { String(format: "%02x", $0) }.joined()
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', 9999999999, NULL, NULL)")
        execute("INSERT INTO settings VALUES ('emergency_stop', 'true')")
        XCTAssertFalse(NativeMCPAuthorization(databaseURL: databaseURL).validateAccessToken("secret-access"))
    }

    func testPathBoundariesAndSessionExpiration() throws {
        let root = directory.appendingPathComponent("project")
        let sibling = directory.appendingPathComponent("project-evil")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        execute("INSERT INTO permission_grants VALUES ('folder', '\(root.path)', NULL, \(future))")
        execute("INSERT INTO project_sessions VALUES ('session-1', '\(root.path)', 'active', \(future), NULL)")
        let auth = NativeMCPAuthorization(databaseURL: databaseURL)
        XCTAssertTrue(auth.isFolderAuthorized(root.appendingPathComponent("src/file.swift")))
        XCTAssertFalse(auth.isFolderAuthorized(sibling.appendingPathComponent("private.txt")))
        XCTAssertTrue(auth.isProjectSessionActive("session-1", root: root))
        XCTAssertFalse(auth.isProjectSessionActive("session-1", root: sibling))
        execute("UPDATE project_sessions SET expires_at = 1")
        XCTAssertFalse(auth.isProjectSessionActive("session-1", root: root))
    }



    func testSwiftListenerAnswersLoopbackWithoutPython() async throws {
        let port = UInt16.random(in: 24000...36000)
        let listener = NativeMCPListener(
            port: port, authorization: NativeMCPAuthorization(databaseURL: databaseURL))
        try listener.start()
        defer { listener.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        var lastError: Error?
        for _ in 0..<12 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("native-experimental"))
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 75_000_000)
            }
        }
        XCTFail("Native loopback listener never became ready: \(String(describing: lastError))")
    }

    func testNativeReadToolsRequireProjectSessionAndStayInsideScope() throws {
        let root = directory.appendingPathComponent("workspace")
        let outside = directory.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try "hello native".write(to: root.appendingPathComponent("hello.txt"),
                                 atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        execute("INSERT INTO project_sessions VALUES ('read-session', '\(root.path)', 'active', 9999999999, NULL)")
        let access = NativeMCPProjectFiles(authorization: .init(databaseURL: databaseURL))
        XCTAssertEqual(try access.read(sessionID: "read-session", projectRoot: root.path, path: "hello.txt"),
                       "hello native")
        XCTAssertThrowsError(try access.read(sessionID: "read-session", projectRoot: root.path, path: "../secret.txt"))
        XCTAssertThrowsError(try access.read(sessionID: "read-session", projectRoot: root.path, path: "escape.txt"))
        XCTAssertThrowsError(try access.read(sessionID: "invalid", projectRoot: root.path, path: "hello.txt"))
        let entries = try access.list(sessionID: "read-session", projectRoot: root.path, folder: ".")
        XCTAssertEqual(entries.map { $0["name"] }, ["hello.txt"])
        execute("INSERT INTO settings VALUES ('emergency_stop', 'true')")
        XCTAssertThrowsError(try access.read(sessionID: "read-session", projectRoot: root.path, path: "hello.txt"))
    }


    func testNativeMCPReadOnlyCallsUseLegacyOAuthAndSession() throws {
        let root = directory.appendingPathComponent("native-workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "public example".write(to: root.appendingPathComponent("sample.txt"),
                                   atomically: true, encoding: .utf8)
        let digest = SHA256.hash(data: Data("native-oauth".utf8))
            .map { String(format: "%02x", $0) }.joined()
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', 9999999999, NULL, NULL)")
        execute("INSERT INTO project_sessions VALUES ('native-session', '\(root.path)', 'active', 9999999999, NULL)")
        let http = NativeMCPHTTP(authorization: .init(databaseURL: databaseURL), port: 18765)
        let headers = ["host": "127.0.0.1:18765", "authorization": "Bearer native-oauth"]
        let listCall: [String: Any] = [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": [
                "name": "read_project_file",
                "arguments": [
                    "session_id": "native-session", "project_root": root.path, "path": "sample.txt"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: listCall)
        let result = http.handle(method: "POST", path: "/mcp", headers: headers, body: data)
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(String(decoding: result.body, as: UTF8.self).contains("public example"))
        var dangerous = listCall
        dangerous["params"] = ["name": "run_project_command", "arguments": [:]]
        let denied = http.handle(method: "POST", path: "/mcp", headers: headers,
                                 body: try JSONSerialization.data(withJSONObject: dangerous))
        XCTAssertTrue(String(decoding: denied.body, as: UTF8.self).contains("-32601"))
        execute("INSERT INTO settings VALUES ('emergency_stop', 'true')")
        XCTAssertEqual(http.handle(method: "POST", path: "/mcp", headers: headers, body: data).status, 401)
    }

    func testHTTPRejectsRequestsWithoutOAuthAndDangerousTools() {
        let http = NativeMCPHTTP(authorization: .init(databaseURL: databaseURL), port: 18765)
        let headers = ["host": "127.0.0.1:18765"]
        XCTAssertEqual(http.handle(method: "POST", path: "/mcp", headers: headers,
                                   body: Data("{}".utf8)).status, 401)
        XCTAssertEqual(http.handle(method: "POST", path: "/mcp",
                                   headers: headers.merging(["origin": "https://evil.example"]) { _, new in new },
                                   body: Data("{}".utf8)).status, 403)
        XCTAssertEqual(http.handle(method: "POST", path: "/mcp",
                                   headers: ["host": "evil.example:18765"],
                                   body: Data("{}".utf8)).status, 400)
        XCTAssertEqual(http.handle(method: "GET", path: "/health", headers: headers, body: Data()).status, 200)
    }
}
