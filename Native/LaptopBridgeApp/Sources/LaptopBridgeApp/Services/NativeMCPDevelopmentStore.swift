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
