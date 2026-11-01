// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPOAuth.swift
import Foundation
import CryptoKit
import SQLite3
import Security

/// OAuth 2.1 authorization-code/PKCE implementation for the *loopback-only*
/// Swift development runtime. It is not a public authorization server.
/// Native window decisions are the sole way to approve connections.
final class NativeMCPOAuth {
    enum OAuthError: Error { case invalidClient, invalidRequest, invalidGrant, denied, database }
    enum Status { case pending, denied, redirect(URL) }

    let store: NativeMCPDevelopmentStore
    let approvals: NativeMCPApprovalStore
    var issuer: String { "http://127.0.0.1:\(store.port)" }

    init(store: NativeMCPDevelopmentStore) {
        self.store = store
        self.approvals = NativeMCPApprovalStore(databaseURL: store.databaseURL)
    }

    private func connect() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let opened = db else {
            if db != nil { sqlite3_close(db) }
            throw OAuthError.database
        }
        sqlite3_busy_timeout(opened, 2000)
        return opened
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw OAuthError.database }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else { throw OAuthError.database }
        for (offset, arg) in args.enumerated() {
            let result = arg.withCString {
                sqlite3_bind_text(stmt, Int32(offset + 1), $0, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { sqlite3_finalize(stmt); throw OAuthError.database }
        }
        return stmt
    }

    private func ensure(_ db: OpaquePointer) throws {
        try execute(db, """
            CREATE TABLE IF NOT EXISTS native_oauth_clients (
              id TEXT PRIMARY KEY, redirect TEXT NOT NULL, name TEXT NOT NULL, created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS native_oauth_requests (
              id TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect TEXT NOT NULL,
              state TEXT, challenge TEXT NOT NULL, created REAL NOT NULL,
              resource TEXT NOT NULL, code_issued REAL
            );
            CREATE TABLE IF NOT EXISTS native_oauth_codes (
              digest TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect TEXT NOT NULL,
              challenge TEXT NOT NULL, resource TEXT NOT NULL, expires REAL NOT NULL,
              consumed REAL
            );
        """)
    }

    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OAuthError.database
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validRedirect(_ raw: String) -> Bool {
        guard let url = URLComponents(string: raw), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host),
              url.user == nil, url.password == nil, url.fragment == nil,
              (url.port ?? 0) > 0, !raw.contains("\r"), !raw.contains("\n"),
              raw.utf8.count < 1024 else { return false }
        return true
    }

    func register(_ payload: [String: Any]) throws -> [String: Any] {
        guard let redirects = payload["redirect_uris"] as? [String],
              redirects.count == 1, let redirect = redirects.first,
              validRedirect(redirect),
              let name = payload["client_name"] as? String,
              !name.isEmpty, name.utf8.count < 128 else { throw OAuthError.invalidRequest }
        let id = try randomSecret()
        let db = try connect()
        defer { sqlite3_close(db) }
        try ensure(db)
        let stmt = try query(db, """
            INSERT INTO native_oauth_clients (id, redirect, name, created) VALUES (?, ?, ?, ?)
        """, [id, redirect, name])
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OAuthError.database }
        return ["client_id": id, "client_name": name,
                "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"], "scope": "mcp",
                "token_endpoint_auth_method": "none"]
    }

    func authorize(_ params: [String: String]) throws -> String {
        guard let clientID = params["client_id"], let redirect = params["redirect_uri"],
              let challenge = params["code_challenge"],
              let state = params["state"],
              state.utf8.count <= 1024,
              params["response_type"] == "code",
              params["code_challenge_method"] == "S256",
              params["scope"] == nil || params["scope"] == "mcp",
              challenge.count == 43, challenge.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              }), validRedirect(redirect),
              params["resource"] == nil || params["resource"] == store.endpoint
        else { throw OAuthError.invalidRequest }
        let db = try connect()
        defer { sqlite3_close(db) }
        try ensure(db)
        let registered: Bool = try {
            let client = try query(db, "SELECT id FROM native_oauth_clients WHERE id = ? AND redirect = ?",
                                   [clientID, redirect])
            defer { sqlite3_finalize(client) }
            return sqlite3_step(client) == SQLITE_ROW
        }()
        guard registered else { throw OAuthError.invalidClient }
        let pending = try approvals.enqueue(kind: "oauth_connection",
            target: "OAuth client \(clientID.prefix(16))… requests mcp at \(redirect)")
        let stmt = try query(db, """
            INSERT INTO native_oauth_requests
                (id, client_id, redirect, state, challenge, created, resource)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [pending.id, clientID, redirect, state, challenge])
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        let resource = store.endpoint
        let b = resource.withCString {
            sqlite3_bind_text(stmt, 7, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard b == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw OAuthError.database }
        return pending.id
    }

    func approvalStatus(_ id: String) throws -> Status {
        guard UUID(uuidString: id) != nil else { throw OAuthError.invalidRequest }
        let db = try connect()
        defer { sqlite3_close(db) }
        try ensure(db)
        // Never hold an OAuth SELECT cursor while taking an approval-store
        // write lock in another connection. Copy fields and finalize first.
        let pending = try {
            let stmt = try query(db, """
                SELECT client_id, redirect, state, challenge, resource, created, code_issued
                FROM native_oauth_requests WHERE id = ?
            """, [id])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let c = sqlite3_column_text(stmt, 0),
                  let r = sqlite3_column_text(stmt, 1),
                  let h = sqlite3_column_text(stmt, 3),
                  let e = sqlite3_column_text(stmt, 4),
                  sqlite3_column_type(stmt, 6) == SQLITE_NULL,
                  sqlite3_column_double(stmt, 5) + 300 > Date().timeIntervalSince1970
            else { return nil as (String, String, String?, String, String)? }
            return (String(cString: c), String(cString: r),
                    sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    String(cString: h), String(cString: e))
        }()
        guard let (client, redirect, state, challenge, resource) = pending else { return .denied }
        if try approvals.pending().contains(where: { $0.id == id }) { return .pending }
        let authorized: NativeMCPApprovalStore.ApprovedRequest
        do { authorized = try approvals.consume(id: id) }
        catch { return .denied }
        guard authorized.kind == "oauth_connection", authorized.decision != .deny else { return .denied }
        let code = try randomSecret()
        let insert = try query(db, """
            INSERT INTO native_oauth_codes (digest, client_id, redirect, challenge, resource, expires)
            VALUES (?, ?, ?, ?, ?, ?)
        """, [hash(code), client, redirect, challenge, resource])
        defer { sqlite3_finalize(insert) }
        sqlite3_bind_double(insert, 6, Date().timeIntervalSince1970 + 300)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw OAuthError.database }
        let update = try query(db, "UPDATE native_oauth_requests SET code_issued = ? WHERE id = ?",
                               [String(Date().timeIntervalSince1970), id])
        defer { sqlite3_finalize(update) }
        guard sqlite3_step(update) == SQLITE_DONE else { throw OAuthError.database }
        var callback = URLComponents(string: redirect)!
        var queryItems = callback.queryItems ?? []
        queryItems.append(.init(name: "code", value: code))
        if let state { queryItems.append(.init(name: "state", value: state)) }
        callback.queryItems = queryItems
        return .redirect(callback.url!)
    }

    private func issue(_ db: OpaquePointer, clientID: String, resource: String) throws -> [String: Any] {
        let access = try randomSecret()
        let refresh = try randomSecret()
        let grant = try randomSecret()
        let now = Date().timeIntervalSince1970
        for (value, type, ttl) in [(access, "access", 3600.0),
                                   (refresh, "refresh", 30.0 * 24 * 3600)] {
            let stmt = try query(db, """
                INSERT INTO oauth_tokens
                (token_digest, grant_id, token_type, client_id, scopes_json, resource,
                 created_at, expires_at, revoked_at)
                VALUES (?, ?, ?, ?, '["mcp"]', ?, ?, ?, NULL)
            """, [hash(value), grant, type, clientID, resource])
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_double(stmt, 7, now + ttl)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw OAuthError.database }
        }
        return ["access_token": access, "refresh_token": refresh, "token_type": "Bearer",
                "scope": "mcp", "expires_in": 3600]
    }

    func token(_ params: [String: String]) throws -> [String: Any] {
        guard let grant = params["grant_type"], let client = params["client_id"] else {
            throw OAuthError.invalidRequest
        }
        let db = try connect()
        defer { sqlite3_close(db) }
        try ensure(db)
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let resource: String
            if grant == "authorization_code" {
                guard let code = params["code"], let redirect = params["redirect_uri"],
                      let verifier = params["code_verifier"],
                      (43...128).contains(verifier.count) else { throw OAuthError.invalidGrant }
                let stmt = try query(db, """
                    SELECT challenge, resource FROM native_oauth_codes
                    WHERE digest = ? AND client_id = ? AND redirect = ?
                      AND consumed IS NULL AND expires > ?
                """, [hash(code), client, redirect])
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_ROW,
                      let challenge = sqlite3_column_text(stmt, 0),
                      let resourcePtr = sqlite3_column_text(stmt, 1)
                else { throw OAuthError.invalidGrant }
                let computed = Data(SHA256.hash(data: Data(verifier.utf8)))
                    .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                guard computed == String(cString: challenge) else { throw OAuthError.invalidGrant }
                resource = String(cString: resourcePtr)
                let used = try query(db, """
                    UPDATE native_oauth_codes SET consumed = ?
                    WHERE digest = ? AND consumed IS NULL
                """, [String(Date().timeIntervalSince1970), hash(code)])
                defer { sqlite3_finalize(used) }
                guard sqlite3_step(used) == SQLITE_DONE,
                      sqlite3_changes(db) == 1 else { throw OAuthError.invalidGrant }
            } else if grant == "refresh_token" {
                guard let refresh = params["refresh_token"] else { throw OAuthError.invalidGrant }
                let stmt = try query(db, """
                    SELECT grant_id, resource FROM oauth_tokens
                    WHERE token_digest = ? AND token_type = 'refresh'
                      AND client_id = ? AND revoked_at IS NULL AND expires_at > ?
                """, [hash(refresh), client])
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_ROW,
                      let oldGrant = sqlite3_column_text(stmt, 0),
                      let resourcePtr = sqlite3_column_text(stmt, 1)
                else { throw OAuthError.invalidGrant }
                resource = String(cString: resourcePtr)
                let revoke = try query(db, """
                    UPDATE oauth_tokens SET revoked_at = ? WHERE grant_id = ? AND revoked_at IS NULL
                """, [String(Date().timeIntervalSince1970), String(cString: oldGrant)])
                defer { sqlite3_finalize(revoke) }
                guard sqlite3_step(revoke) == SQLITE_DONE else { throw OAuthError.database }
            } else { throw OAuthError.invalidRequest }
            let result = try issue(db, clientID: client, resource: resource)
            try execute(db, "COMMIT")
            return result
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    func revoke(token: String, clientID: String) throws {
        let db = try connect()
        defer { sqlite3_close(db) }
        let stmt = try query(db, """
            UPDATE oauth_tokens SET revoked_at = ?
            WHERE grant_id IN (
                SELECT grant_id FROM oauth_tokens
                WHERE token_digest = ? AND client_id = ?
            ) AND revoked_at IS NULL
        """, [String(Date().timeIntervalSince1970), hash(token), clientID])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw OAuthError.database }
    }

    func metadata() -> [String: Any] {
        ["issuer": issuer, "authorization_endpoint": issuer + "/authorize",
         "token_endpoint": issuer + "/token", "registration_endpoint": issuer + "/register",
         "revocation_endpoint": issuer + "/revoke",
         "grant_types_supported": ["authorization_code", "refresh_token"],
         "response_types_supported": ["code"], "code_challenge_methods_supported": ["S256"],
         "scopes_supported": ["mcp"], "token_endpoint_auth_methods_supported": ["none"]]
    }
}
