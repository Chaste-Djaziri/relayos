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
            "CREATE TABLE oauth_tokens (token_digest TEXT, token_type TEXT, expires_at REAL, revoked_at REAL, resource TEXT, scopes_json TEXT)",
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
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', \(future), NULL, 'https://agent.example/mcp', '[\"mcp\"]')")
        let auth = NativeMCPAuthorization(databaseURL: databaseURL)
        XCTAssertTrue(auth.validateAccessToken("secret-access", resource: "https://agent.example/mcp"))
        XCTAssertFalse(auth.validateAccessToken("other-access"))
        XCTAssertFalse(auth.validateAccessToken("secret-access", resource: "https://wrong.example/mcp"))
        execute("UPDATE oauth_tokens SET revoked_at = 1")
        XCTAssertFalse(auth.validateAccessToken("secret-access"))
    }

    func testOAuthTokenMustIncludeExactMcpScope() {
        let digest = SHA256.hash(data: Data("wrong-scope-token".utf8))
            .map { String(format: "%02x", $0) }.joined()
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', 9999999999, NULL, NULL, '[\"not-mcp\"]')")
        XCTAssertFalse(NativeMCPAuthorization(databaseURL: databaseURL).validateAccessToken("wrong-scope-token"))
    }

    func testEmergencyStopOverridesApprovedAccess() {
        let digest = SHA256.hash(data: Data("secret-access".utf8))
            .map { String(format: "%02x", $0) }.joined()
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', 9999999999, NULL, NULL, '[\"mcp\"]')")
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


    func testSwiftOnlyEndToEndLoopbackAuthenticationAndProjectReading() async throws {
        let port = UInt16.random(in: 37000...49000)
        let store = NativeMCPDevelopmentStore(
            directory: directory.appendingPathComponent("native-network"),
            port: port)
        let auth = try store.bootstrap()
        let folder = directory.appendingPathComponent("native-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "verified Swift read".write(
            to: folder.appendingPathComponent("hello.txt"),
            atomically: true, encoding: .utf8)
        let session = try store.grantProjectFolder(folder)
        let token = try String(contentsOf: store.credentialURL, encoding: .utf8)
        let listener = NativeMCPListener(port: port, authorization: auth)
        try listener.start()
        defer { listener.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var authorized = URLRequest(url: url)
        authorized.httpMethod = "POST"
        authorized.timeoutInterval = 2
        authorized.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorized.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": [
                "name": "read_project_file",
                "arguments": [
                    "session_id": session, "project_root": folder.path, "path": "hello.txt"
                ]
            ]
        ] as [String: Any])
        var lastError: Error?
        var received = false
        for _ in 0..<16 {
            do {
                let (data, response) = try await URLSession.shared.data(for: authorized)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("verified Swift read"))
                received = true
                break
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        XCTAssertTrue(received, "Native listener did not reply: \(String(describing: lastError))")
        try store.revokeSession(session)
        let (revokedData, revokedResponse) = try await URLSession.shared.data(for: authorized)
        XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: revokedData, as: UTF8.self).contains("-32003"))
        var denied = authorized
        denied.setValue("Bearer wrong-token", forHTTPHeaderField: "Authorization")
        let (_, deniedResponse) = try await URLSession.shared.data(for: denied)
        XCTAssertEqual((deniedResponse as? HTTPURLResponse)?.statusCode, 401)
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
        execute("INSERT INTO oauth_tokens VALUES ('\(digest)', 'access', 9999999999, NULL, 'http://127.0.0.1:18765/mcp', '[\"mcp\"]')")
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


    func testSwiftOnlyDevelopmentStoreIsIsolatedAndLocallyApproved() throws {
        let root = directory.appendingPathComponent("swift-only-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NativeMCPDevelopmentStore(
            directory: directory.appendingPathComponent("isolated-native-state"),
            port: 18765)
        let auth = try store.bootstrap()
        let token = try String(contentsOf: store.credentialURL, encoding: .utf8)
        XCTAssertGreaterThan(token.count, 30)
        XCTAssertTrue(auth.validateAccessToken(token, resource: store.endpoint))
        XCTAssertFalse(auth.validateAccessToken(token, resource: "https://unrelated.example/mcp"))
        XCTAssertFalse(auth.validateAccessToken("guessed-test-token"))
        let session = try store.grantProjectFolder(root, duration: 60)
        XCTAssertTrue(auth.isProjectSessionActive(session, root: root))
        XCTAssertFalse(auth.isProjectSessionActive(session, root: directory))
        try store.revokeSession(session)
        XCTAssertFalse(auth.isProjectSessionActive(session, root: root))
        let mode = try FileManager.default.attributesOfItem(atPath: store.credentialURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }


    func testNativeSystemStatusAndFixedReadOnlyProcessListing() throws {
        let probe = NativeMCPSystem()
        let status = probe.status()
        XCTAssertTrue((status["hostname"] as? String)?.isEmpty == false)
        XCTAssertTrue((status["os"] as? String)?.contains("macOS") == true)
        let processes = try probe.listProcesses(limit: 8, sortBy: "memory")
        XCTAssertLessThanOrEqual(processes.count, 8)
        XCTAssertTrue(processes.allSatisfy { ($0["pid"] as? Int ?? 0) > 0 })
        XCTAssertThrowsError(try probe.listProcesses(limit: 0, sortBy: "cpu"))
        XCTAssertThrowsError(try probe.listProcesses(limit: 999, sortBy: "cpu"))
        XCTAssertThrowsError(try probe.listProcesses(limit: 8, sortBy: "arbitrary"))
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

    func testNativeApprovalIsConsumedExactlyOnce() throws {
        let store = NativeMCPApprovalStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_000)
        let request = try store.enqueue(kind: "project_command", target: "swift test", now: now)
        try store.decide(id: request.id, decision: .once, now: now.addingTimeInterval(1))
        let approved = try store.consume(id: request.id, now: now.addingTimeInterval(2))
        XCTAssertEqual(approved.kind, "project_command")
        XCTAssertEqual(approved.target, "swift test")
        XCTAssertEqual(approved.decision, .once)
        XCTAssertThrowsError(try store.consume(id: request.id, now: now.addingTimeInterval(3))) {
            XCTAssertEqual($0 as? NativeMCPApprovalStore.StoreError, .expiredOrDecided)
        }
    }

    func testNativeApprovalRejectsStaleAndConflictingDecisions() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let store = NativeMCPApprovalStore(databaseURL: databaseURL, approvalLifetime: 5)
        let request = try store.enqueue(kind: "project_session", target: directory.path, now: now)
        try store.decide(id: request.id, decision: .session, now: now.addingTimeInterval(1))
        XCTAssertThrowsError(try store.decide(id: request.id, decision: .always,
                                              now: now.addingTimeInterval(2))) {
            XCTAssertEqual($0 as? NativeMCPApprovalStore.StoreError, .expiredOrDecided)
        }
        let expired = try store.enqueue(kind: "project_session", target: directory.path, now: now)
        XCTAssertThrowsError(try store.decide(id: expired.id, decision: .once,
                                              now: now.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? NativeMCPApprovalStore.StoreError, .expiredOrDecided)
        }
    }

    func testNativeApprovalFailsClosedWhenEmergencyStopIsSet() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let store = NativeMCPApprovalStore(databaseURL: databaseURL)
        let request = try store.enqueue(kind: "project_write", target: directory.path, now: now)
        execute("INSERT INTO settings VALUES ('emergency_stop', 'true')")
        XCTAssertThrowsError(try store.decide(id: request.id, decision: .once,
                                              now: now.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? NativeMCPApprovalStore.StoreError, .emergencyStop)
        }
        XCTAssertThrowsError(try store.consume(id: request.id, now: now.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? NativeMCPApprovalStore.StoreError, .emergencyStop)
        }
    }
}
