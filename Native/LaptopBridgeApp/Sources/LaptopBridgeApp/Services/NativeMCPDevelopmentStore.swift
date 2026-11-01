// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPDevelopmentStore.swift
import Foundation
import Security
import CryptoKit
import SQLite3
import Darwin

/// Isolated local-only credentials and consent state for Xcode's native Swift
/// runtime. Never writes to the installed Python agent's state directory.
struct NativeMCPDevelopmentStore {
    let directory: URL
    let port: UInt16

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".relayos-swift-dev", isDirectory: true),
         port: UInt16 = 18765) {
        self.directory = directory
        self.port = port
    }

    var databaseURL: URL { directory.appendingPathComponent("state.sqlite3") }
    var credentialURL: URL { directory.appendingPathComponent("local-test-token") }
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    enum StoreError: Error { case storage, randomness, unsafeFile, missingToken }

    private func secret() throws -> String {
        var data = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, data.count, &data) == errSecSuccess else {
            throw StoreError.randomness
        }
        return Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sql(_ db: OpaquePointer, _ statement: String) throws {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw StoreError.storage }
    }

    private func connect() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let connection = db else {
            if db != nil { sqlite3_close(db) }
            throw StoreError.storage
        }
        sqlite3_busy_timeout(connection, 2000)
        return connection
    }

    private func bind(_ text: String, to stmt: OpaquePointer, at index: Int32) throws {
        let result = text.withCString {
            sqlite3_bind_text(stmt, index, $0, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw StoreError.storage }
    }

    private func prepare(_ db: OpaquePointer, _ statement: String) throws -> OpaquePointer {
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &ptr, nil) == SQLITE_OK, let query = ptr else {
            throw StoreError.storage
        }
        return query
    }

    private func readExistingToken() throws -> String? {
        var statBuf = stat()
        guard lstat(credentialURL.path, &statBuf) == 0 else { return nil }
        guard (statBuf.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (statBuf.st_mode & 0o077) == 0,
              statBuf.st_uid == getuid() else { throw StoreError.unsafeFile }
        let data = try Data(contentsOf: credentialURL)
        guard let token = String(data: data, encoding: .utf8),
              token.count > 30, token.count < 200 else { throw StoreError.unsafeFile }
        return token
    }

    private func createToken() throws -> String {
        if let token = try readExistingToken() { return token }
        let value = try secret()
        let fd = open(credentialURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.unsafeFile }
        defer { close(fd) }
        let written = value.withCString { ptr in
            Darwin.write(fd, ptr, value.utf8.count)
        }
        guard written == value.utf8.count else { throw StoreError.storage }
        return value
    }

    /// Initializes a real, isolated SQLite state store with a local test client.
    /// The token expires every 24h; no real OAuth client is registered.
    func bootstrap() throws -> NativeMCPAuthorization {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let db = try connect()
        defer { sqlite3_close(db) }
        try sql(db, """
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS oauth_tokens (
                token_digest TEXT PRIMARY KEY, grant_id TEXT NOT NULL, token_type TEXT NOT NULL,
                client_id TEXT NOT NULL, scopes_json TEXT NOT NULL, resource TEXT,
                created_at REAL NOT NULL, expires_at REAL NOT NULL, revoked_at REAL);
            CREATE TABLE IF NOT EXISTS project_sessions (
                token TEXT PRIMARY KEY, root TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL NOT NULL, status TEXT NOT NULL, decided_at REAL,
                revoked_at REAL, request_id TEXT);
            CREATE TABLE IF NOT EXISTS permission_grants (
                token TEXT PRIMARY KEY, grant_type TEXT NOT NULL, duration TEXT NOT NULL,
                scope TEXT NOT NULL, details_json TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL, revoked_at REAL);
        """)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        let token = try createToken()
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        let query = try prepare(db, """
            INSERT INTO oauth_tokens (
                token_digest, grant_id, token_type, client_id, scopes_json, resource,
                created_at, expires_at, revoked_at)
            VALUES (?, 'local-debug', 'access', 'relayos-dev', '["mcp"]', ?, ?, ?, NULL)
            ON CONFLICT(token_digest) DO UPDATE SET
                expires_at = excluded.expires_at, revoked_at = NULL
        """)
        defer { sqlite3_finalize(query) }
        try bind(digest, to: query, at: 1)
        try bind(endpoint, to: query, at: 2)
        sqlite3_bind_double(query, 3, now)
        sqlite3_bind_double(query, 4, now + 86400)
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.storage }
        return NativeMCPAuthorization(databaseURL: databaseURL)
    }

    /// A session may only be created after an explicit local NSOpenPanel action.
    @discardableResult
    func grantProjectFolder(_ root: URL, duration: TimeInterval = 3600) throws -> String {
        guard root.isFileURL else { throw StoreError.unsafeFile }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &folder),
              folder.boolValue else { throw StoreError.unsafeFile }
        let id = try secret()
        let db = try connect()
        defer { sqlite3_close(db) }
        let query = try prepare(db, """
            INSERT INTO project_sessions
             (token, root, created_at, expires_at, status, decided_at, revoked_at, request_id)
            VALUES (?, ?, ?, ?, 'active', ?, NULL, NULL)
        """)
        defer { sqlite3_finalize(query) }
        let now = Date().timeIntervalSince1970
        try bind(id, to: query, at: 1)
        try bind(canonical.path, to: query, at: 2)
        sqlite3_bind_double(query, 3, now)
        sqlite3_bind_double(query, 4, now + min(max(duration, 60), 3600))
        sqlite3_bind_double(query, 5, now)
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.storage }
        return id
    }

    func revokeSession(_ id: String) throws {
        let db = try connect()
        defer { sqlite3_close(db) }
        let query = try prepare(db, "UPDATE project_sessions SET status = 'revoked', revoked_at = ? WHERE token = ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, Date().timeIntervalSince1970)
        try bind(id, to: query, at: 2)
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.storage }
    }
}

/// Native, local-only approval state.  This is deliberately separate from the
/// installed application's Python state until a reversible migration has been
/// validated.  Remote MCP requests may enqueue an approval, but only the
/// companion UI is allowed to call `decide`.
struct NativeMCPApprovalStore {
    enum Decision: String, CaseIterable {
        case once, session, always, deny
    }

    struct Request: Equatable {
        let id: String
        let kind: String
        let target: String
        let createdAt: Date
        let expiresAt: Date
    }

    struct ApprovedRequest: Equatable {
        let id: String
        let kind: String
        let target: String
        let decision: Decision
    }

    enum StoreError: Error, Equatable {
        case unavailable
        case invalidRequest
        case expiredOrDecided
        case emergencyStop
    }

    private let databaseURL: URL
    private let approvalLifetime: TimeInterval

    init(databaseURL: URL, approvalLifetime: TimeInterval = 300) {
        self.databaseURL = databaseURL
        self.approvalLifetime = approvalLifetime
    }

    private func connect() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw StoreError.unavailable
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
    }

    private func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw StoreError.unavailable }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.unavailable }
        return statement
    }

    private func setup(_ db: OpaquePointer) throws {
        try execute(db, """
            CREATE TABLE IF NOT EXISTS native_approval_requests (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL,
                created_at REAL NOT NULL, expires_at REAL NOT NULL,
                status TEXT NOT NULL, decision TEXT, decided_at REAL, consumed_at REAL
            );
            CREATE TABLE IF NOT EXISTS native_approval_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL,
                event TEXT NOT NULL, recorded_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS native_approval_pending
                ON native_approval_requests(status, expires_at, created_at);
        """)
    }

    private func isEmergencyStopped(_ db: OpaquePointer) throws -> Bool {
        let statement = try prepare(db, "SELECT value FROM settings WHERE key = 'emergency_stop'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: value) == "true"
    }

    private func expire(_ db: OpaquePointer, now: Date) throws {
        let statement = try prepare(db, """
            UPDATE native_approval_requests
               SET status = 'expired', decided_at = ?
             WHERE status = 'pending' AND expires_at <= ?
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
    }

    @discardableResult
    func enqueue(kind: String, target: String, now: Date = Date()) throws -> Request {
        guard !kind.isEmpty, !target.isEmpty, kind.utf8.count <= 128, target.utf8.count <= 4_096 else {
            throw StoreError.invalidRequest
        }
        let request = Request(id: UUID().uuidString.lowercased(), kind: kind, target: target,
                              createdAt: now, expiresAt: now.addingTimeInterval(approvalLifetime))
        let db = try connect()
        defer { sqlite3_close(db) }
        try setup(db)
        try execute(db, "BEGIN IMMEDIATE")
        do {
            if try isEmergencyStopped(db) { throw StoreError.emergencyStop }
            let statement = try prepare(db, """
                INSERT INTO native_approval_requests
                    (id, kind, target, created_at, expires_at, status)
                VALUES (?, ?, ?, ?, ?, 'pending')
            """)
            defer { sqlite3_finalize(statement) }
            try bind(request.id, statement, 1); try bind(kind, statement, 2); try bind(target, statement, 3)
            sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, request.expiresAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
            try execute(db, "COMMIT")
            return request
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    /// Atomically records exactly one local decision.  A stale or concurrent
    /// decision cannot overwrite an already approved/denied request.
    func decide(id: String, decision: Decision, now: Date = Date()) throws {
        let db = try connect()
        defer { sqlite3_close(db) }
        try setup(db)
        try execute(db, "BEGIN IMMEDIATE")
        do {
            try expire(db, now: now)
            if decision != .deny, try isEmergencyStopped(db) { throw StoreError.emergencyStop }
            let statement = try prepare(db, """
                UPDATE native_approval_requests
                   SET status = ?, decision = ?, decided_at = ?
                 WHERE id = ? AND status = 'pending' AND expires_at > ?
            """)
            defer { sqlite3_finalize(statement) }
            let status = decision == .deny ? "denied" : "approved"
            try bind(status, statement, 1); try bind(decision.rawValue, statement, 2)
            sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
            try bind(id, statement, 4); sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                throw StoreError.expiredOrDecided
            }
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    /// Consumes an approval once, in the same transaction used to validate it.
    /// This is the replay barrier before a permission-expanding operation runs.
    func consume(id: String, now: Date = Date()) throws -> ApprovedRequest {
        let db = try connect()
        defer { sqlite3_close(db) }
        try setup(db)
        try execute(db, "BEGIN IMMEDIATE")
        do {
            if try isEmergencyStopped(db) { throw StoreError.emergencyStop }
            try expire(db, now: now)
            let select = try prepare(db, """
                SELECT kind, target, decision FROM native_approval_requests
                 WHERE id = ? AND status = 'approved' AND consumed_at IS NULL AND expires_at > ?
            """)
            defer { sqlite3_finalize(select) }
            try bind(id, select, 1); sqlite3_bind_double(select, 2, now.timeIntervalSince1970)
            guard sqlite3_step(select) == SQLITE_ROW,
                  let kind = sqlite3_column_text(select, 0),
                  let target = sqlite3_column_text(select, 1),
                  let rawDecision = sqlite3_column_text(select, 2),
                  let decision = Decision(rawValue: String(cString: rawDecision)) else {
                throw StoreError.expiredOrDecided
            }
            let update = try prepare(db, """
                UPDATE native_approval_requests SET status = 'consumed', consumed_at = ?
                WHERE id = ? AND status = 'approved' AND consumed_at IS NULL
            """)
            defer { sqlite3_finalize(update) }
            sqlite3_bind_double(update, 1, now.timeIntervalSince1970); try bind(id, update, 2)
            guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                throw StoreError.expiredOrDecided
            }
            try execute(db, "COMMIT")
            return ApprovedRequest(id: id, kind: String(cString: kind), target: String(cString: target), decision: decision)
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }
}
