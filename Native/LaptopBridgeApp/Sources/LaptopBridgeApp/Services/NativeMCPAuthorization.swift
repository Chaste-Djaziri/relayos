// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPAuthorization.swift
import Foundation
import CryptoKit
import SQLite3

/// Read-only bridge into the *existing* authorization database.
/// This intentionally cannot create approvals or weaken the local consent flow.
/// All checks fail closed if the database is missing, unreadable or incompatible.
struct NativeMCPAuthorization {
    let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".laptop-bridge/state.sqlite3")) {
        self.databaseURL = databaseURL
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let db = connection else {
            if connection != nil { sqlite3_close(connection) }
            throw AuthorizationError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    private func scalarInt(_ db: OpaquePointer, sql: String,
                           values: [String] = []) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let query = stmt else { throw AuthorizationError.databaseUnavailable }
        defer { sqlite3_finalize(query) }
        for (index, value) in values.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(query, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw AuthorizationError.databaseUnavailable }
        }
        let rc = sqlite3_step(query)
        if rc == SQLITE_DONE { return 0 }
        guard rc == SQLITE_ROW else { throw AuthorizationError.databaseUnavailable }
        return sqlite3_column_int64(query, 0)
    }

    private func stopped(_ db: OpaquePointer) throws -> Bool {
        try scalarInt(db, sql: "SELECT COUNT(*) FROM settings WHERE key = 'emergency_stop' AND value = 'true'") > 0
    }

    /// Require a real, unrevoked access token, an exact OAuth "mcp" scope,
    /// and a resource binding for the local development listener.
    /// Older tokens with no resource are accepted only for compatibility with
    /// the existing local tests. Never accept a token bound to another MCP URL.
    func validateAccessToken(_ token: String, resource: String? = nil,
                             now: Date = Date()) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 4096 else { return false }
        let digest = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            return try withDatabase { db in
                guard try !stopped(db) else { return false }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    SELECT scopes_json, resource FROM oauth_tokens
                    WHERE token_digest = ? AND token_type = 'access'
                      AND revoked_at IS NULL AND expires_at > ?
                """, -1, &statement, nil) == SQLITE_OK,
                      let query = statement else {
                    throw AuthorizationError.databaseUnavailable
                }
                defer { sqlite3_finalize(query) }
                let result = digest.withCString {
                    sqlite3_bind_text(query, 1, $0, -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard result == SQLITE_OK else { return false }
                sqlite3_bind_double(query, 2, now.timeIntervalSince1970)
                guard sqlite3_step(query) == SQLITE_ROW,
                      let scopeData = sqlite3_column_text(query, 0) else { return false }
                let rawScopes = String(cString: scopeData)
                guard let scopes = try? JSONSerialization.jsonObject(
                    with: Data(rawScopes.utf8)) as? [String],
                    scopes.contains("mcp") else { return false }
                if let expectedResource = resource, sqlite3_column_type(query, 1) != SQLITE_NULL {
                    guard let ptr = sqlite3_column_text(query, 1),
                          String(cString: ptr) == expectedResource else { return false }
                }
                return sqlite3_step(query) == SQLITE_DONE
            }
        } catch { return false }
    }

    func isProjectSessionActive(_ token: String, root: URL, now: Date = Date()) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 4096 else { return false }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        do {
            return try withDatabase { db in
                guard try !stopped(db) else { return false }
                return try scalarInt(db, sql: """
                    SELECT COUNT(*) FROM project_sessions
                    WHERE token = ? AND root = ? AND status = 'active'
                      AND expires_at > ? AND revoked_at IS NULL
                """, values: [token, canonical, String(now.timeIntervalSince1970)]) == 1
            }
        } catch { return false }
    }

    func isFolderAuthorized(_ target: URL, now: Date = Date()) -> Bool {
        let canonical = target.standardizedFileURL.resolvingSymlinksInPath().path
        do {
            return try withDatabase { db in
                guard try !stopped(db) else { return false }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    SELECT scope FROM permission_grants
                    WHERE grant_type = 'folder' AND revoked_at IS NULL
                      AND (expires_at IS NULL OR expires_at > ?)
                """, -1, &statement, nil) == SQLITE_OK, let q = statement
                else { throw AuthorizationError.databaseUnavailable }
                defer { sqlite3_finalize(q) }
                sqlite3_bind_double(q, 1, now.timeIntervalSince1970)
                while sqlite3_step(q) == SQLITE_ROW {
                    guard let ptr = sqlite3_column_text(q, 0) else { continue }
                    let folder = URL(fileURLWithPath: String(cString: ptr)).standardizedFileURL
                        .resolvingSymlinksInPath().path
                    if canonical == folder || canonical.hasPrefix(folder == "/" ? "/" : folder + "/") {
                        return true
                    }
                }
                return false
            }
        } catch { return false }
    }

    enum AuthorizationError: Error { case databaseUnavailable }
}
