"""Transaction-safe local state for approvals and metadata-only auditing."""
import json
import hashlib
import secrets
import sqlite3
import time
from contextlib import contextmanager

from .config import DATABASE_FILE, STATE_DIR

TTL = 300
HISTORY_RETENTION = 30 * 24 * 60 * 60
PROJECT_SESSION_TTL = 60 * 60
JOB_TTL = 30
GUIDANCE_SESSION_TTL = 15 * 60
OAUTH_APPROVAL_TTL = 5 * 60
OAUTH_CODE_TTL = 5 * 60
OAUTH_ACCESS_TOKEN_TTL = 60 * 60
OAUTH_REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60


_INITIALIZED_DBS = set()


@contextmanager
def _db():
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    connection = sqlite3.connect(DATABASE_FILE, timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA busy_timeout=5000")
        db_path = str(DATABASE_FILE)
        if db_path not in _INITIALIZED_DBS:
            try:
                connection.execute("PRAGMA journal_mode=WAL")
            except sqlite3.OperationalError:
                pass
            connection.executescript("""
                CREATE TABLE IF NOT EXISTS requests (
                    token TEXT PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL,
                    argv_json TEXT NOT NULL, created_at REAL NOT NULL, status TEXT NOT NULL,
                    decided_at REAL, consumed_at REAL
                );
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS action_history (
                    id INTEGER PRIMARY KEY, recorded_at REAL NOT NULL, kind TEXT NOT NULL,
                    target TEXT NOT NULL, decision TEXT NOT NULL, exit_code INTEGER, duration_ms INTEGER
                );
                CREATE TABLE IF NOT EXISTS project_sessions (
                    token TEXT PRIMARY KEY, root TEXT NOT NULL, created_at REAL NOT NULL,
                    expires_at REAL NOT NULL, status TEXT NOT NULL, decided_at REAL,
                revoked_at REAL, request_id TEXT
                );
                CREATE TABLE IF NOT EXISTS desktop_jobs (
                    token TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL, status TEXT NOT NULL, result_json TEXT,
                    result_blob BLOB, completed_at REAL
                );
            CREATE TABLE IF NOT EXISTS follow_ups (
                token TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL,
                check_at REAL NOT NULL, expires_at REAL, project_session TEXT,
                metadata_json TEXT NOT NULL, created_at REAL NOT NULL, completed_at REAL
            );
            CREATE TABLE IF NOT EXISTS guidance_sessions (
                token TEXT PRIMARY KEY, created_at REAL NOT NULL,
                expires_at REAL NOT NULL, status TEXT NOT NULL,
                stopped_at REAL, last_capture_at REAL
            );
            CREATE TABLE IF NOT EXISTS guidance_click_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_token TEXT NOT NULL,
                display_id INTEGER NOT NULL, x REAL NOT NULL, y REAL NOT NULL,
                button TEXT NOT NULL, modifiers_json TEXT NOT NULL,
                occurred_at REAL NOT NULL, consumed_at REAL
            );
            CREATE TABLE IF NOT EXISTS command_grants (
                token TEXT PRIMARY KEY, project_root TEXT NOT NULL,
                executable TEXT NOT NULL, argv_digest TEXT,
                working_directory TEXT, grant_type TEXT NOT NULL,
                created_at REAL NOT NULL, expires_at REAL,
                revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS permission_grants (
                token TEXT PRIMARY KEY, grant_type TEXT NOT NULL, duration TEXT NOT NULL,
                scope TEXT NOT NULL, details_json TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL, revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS oauth_clients (
                client_id TEXT PRIMARY KEY, metadata_json TEXT NOT NULL, created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS oauth_authorizations (
                token TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
                state TEXT, scopes_json TEXT NOT NULL, code_challenge TEXT NOT NULL,
                resource TEXT, created_at REAL NOT NULL, status TEXT NOT NULL, decided_at REAL,
                consumed_at REAL
            );
            CREATE TABLE IF NOT EXISTS oauth_codes (
                token_digest TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
                scopes_json TEXT NOT NULL, code_challenge TEXT NOT NULL, resource TEXT,
                created_at REAL NOT NULL, expires_at REAL NOT NULL, consumed_at REAL
            );
            CREATE TABLE IF NOT EXISTS oauth_tokens (
                token_digest TEXT PRIMARY KEY, grant_id TEXT NOT NULL, token_type TEXT NOT NULL,
                client_id TEXT NOT NULL, scopes_json TEXT NOT NULL, resource TEXT,
                created_at REAL NOT NULL, expires_at REAL NOT NULL, revoked_at REAL
            );
            """)
            connection.execute("CREATE INDEX IF NOT EXISTS command_grants_lookup ON command_grants(project_root, executable, grant_type, revoked_at)")
            connection.execute("CREATE INDEX IF NOT EXISTS oauth_tokens_lookup ON oauth_tokens(token_digest, token_type, revoked_at)")
            _INITIALIZED_DBS.add(db_path)
            try:
                connection.execute("ALTER TABLE project_sessions ADD COLUMN request_id TEXT")
            except sqlite3.OperationalError:
                pass
        yield connection
    finally:
        connection.close()


def _expire(connection, now):
    connection.execute("UPDATE requests SET status = 'expired', decided_at = ? WHERE status = 'pending' AND created_at < ?", (now, now - TTL))
    connection.execute("UPDATE project_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
    connection.execute("UPDATE guidance_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
    connection.execute("DELETE FROM desktop_jobs WHERE created_at < ?", (now - JOB_TTL,))


def _record(connection, kind, target, decision, exit_code=None, duration_ms=None):
    now = time.time()
    connection.execute("INSERT INTO action_history (recorded_at, kind, target, decision, exit_code, duration_ms) VALUES (?, ?, ?, ?, ?, ?)", (now, kind, target, decision, exit_code, duration_ms))
    connection.execute("DELETE FROM action_history WHERE recorded_at < ?", (now - HISTORY_RETENTION,))


def request(kind, details):
    token = secrets.token_urlsafe(18)
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        connection.execute("INSERT INTO requests (token, kind, target, argv_json, created_at, status) VALUES (?, ?, ?, ?, ?, 'pending')", (token, kind, details["target"], json.dumps(details["argv"]), time.time()))
        connection.commit()
    return token


def set_emergency_stop(enabled):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("INSERT INTO settings (key, value) VALUES ('emergency_stop', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", ("true" if enabled else "false",))
        if enabled:
            now = time.time()
            connection.execute("UPDATE project_sessions SET status = 'revoked', revoked_at = ? WHERE status = 'active'", (now,))
            connection.execute("UPDATE guidance_sessions SET status = 'stopped', stopped_at = ? WHERE status = 'active'", (now,))
            connection.execute("UPDATE desktop_jobs SET status = 'cancelled', completed_at = ? WHERE status IN ('pending', 'claimed')", (now,))
            connection.execute("UPDATE oauth_tokens SET revoked_at = ? WHERE revoked_at IS NULL", (now,))
            connection.execute("UPDATE oauth_authorizations SET status = 'denied', decided_at = ? WHERE status = 'pending'", (now,))
        connection.commit()


def emergency_stop(connection=None):
    if connection is None:
        with _db() as owned:
            return emergency_stop(owned)
    row = connection.execute("SELECT value FROM settings WHERE key = 'emergency_stop'").fetchone()
    return row is not None and row["value"] == "true"


def approve(token):
    _decide(token, "approved")


def deny(token):
    _decide(token, "denied")


def decide_request(token, duration="once"):
    """Approve a pending request and optionally persist its folder permission."""
    if duration not in {"once", "session", "persistent"}:
        raise ValueError("duration must be once, session, or persistent")
    with _db() as connection:
        row = connection.execute("SELECT kind, target, status FROM requests WHERE token = ?", (token,)).fetchone()
    if row is None or row["status"] != "pending":
        return False
    if duration == "persistent" and row["kind"] == "project_session":
        grant_folder(row["target"], "persistent")
    _decide(token, "approved")
    if row["kind"] == "project_session":
        activate_project_session(token)
    return True


def _decide(token, status):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire(connection, now)
        row = connection.execute("SELECT kind, target, status FROM requests WHERE token = ?", (token,)).fetchone()
        if row is not None and status == "approved" and row["status"] == "approved":
            connection.commit()
            return
        if row is None or row["status"] != "pending":
            connection.rollback()
            raise PermissionError("Unknown, expired, or already decided request")
        connection.execute("UPDATE requests SET status = ?, decided_at = ? WHERE token = ?", (status, now, token))
        _record(connection, row["kind"], row["target"], status)
        connection.commit()


def consume(token):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        _expire(connection, now)
        row = connection.execute("SELECT kind, target, argv_json FROM requests WHERE token = ? AND status = 'approved' AND created_at >= ?", (token, now - TTL)).fetchone()
        if row is None:
            connection.rollback()
            raise PermissionError("Missing, expired, or unapproved request")
        connection.execute("UPDATE requests SET status = 'consumed', consumed_at = ? WHERE token = ?", (now, token))
        connection.commit()
    return {"kind": row["kind"], "details": {"target": row["target"], "argv": json.loads(row["argv_json"])}}


def record_result(kind, target, exit_code=None, duration_ms=None):
    with _db() as connection:
        _record(connection, kind, target, "executed", exit_code, duration_ms)


def pending_requests():
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        rows = connection.execute("SELECT token, kind, target, argv_json, created_at FROM requests WHERE status = 'pending' ORDER BY created_at").fetchall()
        connection.commit()
    return [{"request_id": row["token"], "kind": row["kind"], "target": row["target"], "argv": json.loads(row["argv_json"]), "created_at": row["created_at"]} for row in rows]


def recent_history(limit=100):
    with _db() as connection:
        rows = connection.execute("SELECT recorded_at, kind, target, decision, exit_code, duration_ms FROM action_history ORDER BY recorded_at DESC LIMIT ?", (limit,)).fetchall()
    return [dict(row) for row in rows]


def create_project_session_request(root):
    """Create a local approval request for a selected project root."""
    if emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    return request("project_session", {"target": root, "argv": []})


def activate_project_session(request_id):
    """Atomically consume an approved project-session request and create its session."""
    try:
        item = consume(request_id)
    except PermissionError:
        with _db() as connection:
            existing = connection.execute("SELECT token, root, created_at, expires_at FROM project_sessions WHERE request_id = ? AND status = 'active' AND expires_at > ?", (request_id, time.time())).fetchone()
        if existing:
            return {"session_id": existing["token"], "root": existing["root"], "created_at": existing["created_at"], "expires_at": existing["expires_at"]}
        raise
    if item["kind"] != "project_session":
        raise PermissionError("Request is not a project-session approval")
    token = secrets.token_urlsafe(18)
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        connection.execute(
            "INSERT INTO project_sessions (token, root, created_at, expires_at, status, decided_at, request_id) VALUES (?, ?, ?, ?, 'active', ?, ?)",
            (token, item["details"]["target"], now, now + PROJECT_SESSION_TTL, now, request_id),
        )
        _record(connection, "project_session", item["details"]["target"], "approved")
        connection.commit()
    return {"session_id": token, "root": item["details"]["target"], "expires_at": now + PROJECT_SESSION_TTL}


def project_session(session_id):
    """Return an active project session, or reject expired/revoked sessions."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        _expire(connection, now)
        row = connection.execute(
            "SELECT token, root, created_at, expires_at FROM project_sessions WHERE token = ? AND status = 'active' AND expires_at > ?",
            (session_id, now),
        ).fetchone()
        connection.commit()
    if row is None:
        raise PermissionError("Missing, expired, or revoked project session")
    return {"session_id": row["token"], "root": row["root"], "created_at": row["created_at"], "expires_at": row["expires_at"]}


def active_project_sessions():
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        rows = connection.execute(
            "SELECT token, root, created_at, expires_at FROM project_sessions WHERE status = 'active' ORDER BY created_at DESC"
        ).fetchall()
        connection.commit()
    return [{"session_id": row["token"], "root": row["root"], "created_at": row["created_at"], "expires_at": row["expires_at"]} for row in rows]


def _oauth_digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _expire_oauth(connection, now):
    connection.execute(
        "UPDATE oauth_authorizations SET status = 'expired', decided_at = ? WHERE status = 'pending' AND created_at < ?",
        (now, now - OAUTH_APPROVAL_TTL),
    )
    connection.execute("DELETE FROM oauth_codes WHERE expires_at <= ? OR consumed_at IS NOT NULL", (now,))
    connection.execute("DELETE FROM oauth_tokens WHERE expires_at <= ?", (now,))


def oauth_register_client(client_id, metadata):
    with _db() as connection:
        connection.execute(
            "INSERT INTO oauth_clients (client_id, metadata_json, created_at) VALUES (?, ?, ?) "
            "ON CONFLICT(client_id) DO UPDATE SET metadata_json = excluded.metadata_json",
            (client_id, json.dumps(metadata), time.time()),
        )


def oauth_client(client_id):
    with _db() as connection:
        row = connection.execute("SELECT metadata_json FROM oauth_clients WHERE client_id = ?", (client_id,)).fetchone()
    return json.loads(row["metadata_json"]) if row else None


def create_oauth_authorization(client_id, redirect_uri, state_value, scopes, code_challenge, resource):
    token = secrets.token_urlsafe(24)
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire_oauth(connection, now)
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        connection.execute(
            "INSERT INTO oauth_authorizations (token, client_id, redirect_uri, state, scopes_json, code_challenge, resource, created_at, status) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending')",
            (token, client_id, redirect_uri, state_value, json.dumps(scopes), code_challenge, resource, now),
        )
        connection.commit()
    return token


def pending_oauth_authorizations():
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire_oauth(connection, time.time())
        rows = connection.execute(
            "SELECT a.token, a.client_id, a.redirect_uri, a.scopes_json, a.created_at, c.metadata_json "
            "FROM oauth_authorizations a LEFT JOIN oauth_clients c ON c.client_id = a.client_id "
            "WHERE a.status = 'pending' ORDER BY a.created_at"
        ).fetchall()
        connection.commit()
    result = []
    for row in rows:
        metadata = json.loads(row["metadata_json"] or "{}")
        redirect_uri = row["redirect_uri"]
        client_name = metadata.get("client_name") or metadata.get("client_uri")
        if not client_name:
            lowered = redirect_uri.lower()
            if "claude.ai" in lowered or "claude.com" in lowered:
                client_name = "Claude"
            elif "chatgpt.com" in lowered or "openai.com" in lowered:
                client_name = "ChatGPT"
            elif "googleusercontent.com" in lowered:
                client_name = "Gemini"
        result.append({"request_id": row["token"], "client_id": row["client_id"],
                       "client_name": client_name or "MCP client",
                       "redirect_uri": redirect_uri, "scopes": json.loads(row["scopes_json"]),
                       "created_at": row["created_at"]})
    return result


def decide_oauth_authorization(request_id, approved):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute("SELECT status FROM oauth_authorizations WHERE token = ?", (request_id,)).fetchone()
        if row is None or row["status"] != "pending":
            connection.rollback()
            raise PermissionError("Unknown, expired, or already decided OAuth authorization")
        connection.execute(
            "UPDATE oauth_authorizations SET status = ?, decided_at = ? WHERE token = ?",
            ("approved" if approved else "denied", now, request_id),
        )
        _record(connection, "oauth_authorization", "MCP client", "approved" if approved else "denied")
        connection.commit()


def consume_oauth_authorization(request_id):
    """Turn one locally approved browser request into a one-time OAuth code."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute("SELECT * FROM oauth_authorizations WHERE token = ? AND status = 'approved'", (request_id,)).fetchone()
        if row is None:
            connection.rollback()
            return None
        code = secrets.token_urlsafe(32)
        connection.execute("UPDATE oauth_authorizations SET status = 'consumed', consumed_at = ? WHERE token = ?", (now, request_id))
        connection.execute(
            "INSERT INTO oauth_codes (token_digest, client_id, redirect_uri, scopes_json, code_challenge, resource, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (_oauth_digest(code), row["client_id"], row["redirect_uri"], row["scopes_json"], row["code_challenge"], row["resource"], now, now + OAUTH_CODE_TTL),
        )
        connection.commit()
    return {"code": code, "redirect_uri": row["redirect_uri"], "state": row["state"]}


def oauth_authorization_status(request_id):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire_oauth(connection, time.time())
        row = connection.execute("SELECT status FROM oauth_authorizations WHERE token = ?", (request_id,)).fetchone()
        connection.commit()
    return row["status"] if row else "missing"


def oauth_load_code(code):
    with _db() as connection:
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute("SELECT * FROM oauth_codes WHERE token_digest = ? AND expires_at > ?", (_oauth_digest(code), now)).fetchone()
    return dict(row) if row else None


def oauth_consume_code_and_issue_tokens(code):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute("SELECT * FROM oauth_codes WHERE token_digest = ? AND expires_at > ? AND consumed_at IS NULL", (_oauth_digest(code), now)).fetchone()
        if row is None:
            connection.rollback()
            return None
        connection.execute("UPDATE oauth_codes SET consumed_at = ? WHERE token_digest = ?", (now, row["token_digest"]))
        grant_id, access, refresh = secrets.token_urlsafe(18), secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        scopes = row["scopes_json"]
        connection.executemany(
            "INSERT INTO oauth_tokens (token_digest, grant_id, token_type, client_id, scopes_json, resource, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (_oauth_digest(access), grant_id, "access", row["client_id"], scopes, row["resource"], now, now + OAUTH_ACCESS_TOKEN_TTL),
                (_oauth_digest(refresh), grant_id, "refresh", row["client_id"], scopes, row["resource"], now, now + OAUTH_REFRESH_TOKEN_TTL),
            ],
        )
        connection.commit()
    return {"access_token": access, "refresh_token": refresh, "client_id": row["client_id"], "scopes": json.loads(scopes), "resource": row["resource"]}


def oauth_load_token(token, token_type):
    with _db() as connection:
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute(
            "SELECT * FROM oauth_tokens WHERE token_digest = ? AND token_type = ? AND expires_at > ? AND revoked_at IS NULL",
            (_oauth_digest(token), token_type, now),
        ).fetchone()
    return dict(row) if row else None


def oauth_rotate_refresh_token(refresh_token, scopes):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire_oauth(connection, now)
        row = connection.execute(
            "SELECT * FROM oauth_tokens WHERE token_digest = ? AND token_type = 'refresh' AND expires_at > ? AND revoked_at IS NULL",
            (_oauth_digest(refresh_token), now),
        ).fetchone()
        if row is None:
            connection.rollback()
            return None
        connection.execute("UPDATE oauth_tokens SET revoked_at = ? WHERE grant_id = ? AND revoked_at IS NULL", (now, row["grant_id"]))
        grant_id, access, refresh = secrets.token_urlsafe(18), secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        scopes_json = json.dumps(scopes)
        connection.executemany(
            "INSERT INTO oauth_tokens (token_digest, grant_id, token_type, client_id, scopes_json, resource, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (_oauth_digest(access), grant_id, "access", row["client_id"], scopes_json, row["resource"], now, now + OAUTH_ACCESS_TOKEN_TTL),
                (_oauth_digest(refresh), grant_id, "refresh", row["client_id"], scopes_json, row["resource"], now, now + OAUTH_REFRESH_TOKEN_TTL),
            ],
        )
        connection.commit()
    return {"access_token": access, "refresh_token": refresh, "client_id": row["client_id"], "scopes": scopes, "resource": row["resource"]}


def active_oauth_grants():
    with _db() as connection:
        now = time.time()
        _expire_oauth(connection, now)
        rows = connection.execute(
            "SELECT t.grant_id, t.client_id, t.created_at, t.expires_at, c.metadata_json "
            "FROM oauth_tokens t LEFT JOIN oauth_clients c ON c.client_id = t.client_id "
            "WHERE t.token_type = 'refresh' AND t.revoked_at IS NULL AND t.expires_at > ? ORDER BY t.created_at DESC",
            (now,),
        ).fetchall()
    result = []
    for row in rows:
        metadata = json.loads(row["metadata_json"] or "{}")
        result.append({"grant_id": row["grant_id"], "client_id": row["client_id"],
                       "client_name": metadata.get("client_name") or metadata.get("client_uri") or "MCP client",
                       "created_at": row["created_at"], "expires_at": row["expires_at"]})
    return result


def revoke_oauth_grant(grant_id):
    with _db() as connection:
        connection.execute("UPDATE oauth_tokens SET revoked_at = ? WHERE grant_id = ? AND revoked_at IS NULL", (time.time(), grant_id))


def _command_digest(argv, cwd):
    payload = json.dumps([argv, cwd], ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def grant_project_command(project_root, executable, argv, cwd, grant_type="once"):
    """Save a one-use exact invocation or a persistent executable/project grant."""
    if grant_type not in {"once", "session", "persistent"}:
        if grant_type != "always":
            raise ValueError("grant_type must be once, session, or persistent")
    if emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    token = secrets.token_urlsafe(24)
    now = time.time()
    argv_digest = _command_digest(argv, cwd) if grant_type == "once" else None
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        if grant_type in {"persistent", "always"}:
            connection.execute(
                "UPDATE command_grants SET revoked_at = ? WHERE executable = ? AND grant_type = 'persistent' AND revoked_at IS NULL",
                (now, executable),
            )
        connection.execute(
            "INSERT INTO command_grants (token, project_root, executable, argv_digest, working_directory, grant_type, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (token, project_root, executable, argv_digest, cwd if grant_type == "once" else None, grant_type, now, now + 3600 if grant_type == "session" else (now + 300 if grant_type == "once" else None)),
        )
        _record(connection, "command_grant", f"{project_root}:{executable}", f"approved_{grant_type}")
        connection.commit()
    return token


def consume_project_command_grant(project_root, executable, argv, cwd, grant_token=None):
    """Atomically consume an exact one-use grant or validate a saved executable grant."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        if grant_token:
            row = connection.execute(
                "SELECT token FROM command_grants WHERE token = ? AND project_root = ? AND executable = ? AND argv_digest = ? AND working_directory = ? AND grant_type = 'once' AND revoked_at IS NULL AND expires_at > ?",
                (grant_token, project_root, executable, _command_digest(argv, cwd), cwd, now),
            ).fetchone()
            if row is None:
                connection.rollback()
                raise PermissionError("Missing, expired, mismatched, or already-used command approval")
            connection.execute("DELETE FROM command_grants WHERE token = ?", (grant_token,))
            connection.commit()
            return "approved_once"
        row = connection.execute(
            "SELECT token FROM command_grants WHERE ((grant_type = 'persistent' AND executable = ?) OR (grant_type = 'always' AND project_root = ?)) AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC LIMIT 1",
            (executable, project_root, now),
        ).fetchone()
        if row is None:
            connection.rollback()
            raise PermissionError("Command approval required; request an exact one-time or persistent project command grant first")
        connection.commit()
        return "approved_always"


def saved_command_grants():
    with _db() as connection:
        rows = connection.execute(
            "SELECT token, project_root, executable, grant_type, created_at, expires_at FROM command_grants WHERE grant_type IN ('always', 'persistent') AND revoked_at IS NULL ORDER BY created_at DESC"
        ).fetchall()
    return [dict(row) for row in rows]


def revoke_command_grant(token):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            "UPDATE command_grants SET revoked_at = ? WHERE token = ? AND grant_type IN ('always', 'persistent') AND revoked_at IS NULL",
            (time.time(), token),
        )
        if cursor.rowcount != 1:
            connection.rollback()
            raise ValueError("Saved command grant not found or already revoked")
        connection.commit()


def grant_folder(folder, duration="persistent"):
    """Persist an exact-folder grant; descendants are authorized by the caller."""
    if duration not in {"once", "session", "persistent"}:
        raise ValueError("duration must be once, session, or persistent")
    token = secrets.token_urlsafe(24); now = time.time()
    with _db() as connection:
        connection.execute("INSERT INTO permission_grants VALUES (?, 'folder', ?, ?, ?, ?, NULL, NULL)",
                           (token, duration, folder, json.dumps({"folder": folder}), now))
        connection.commit()
    return token


def folder_granted(folder):
    path = str(folder)
    with _db() as connection:
        now = time.time()
        row = connection.execute(
            "SELECT 1 FROM permission_grants WHERE grant_type = 'folder' AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) AND (? = scope OR ? LIKE scope || '/%') ORDER BY created_at DESC LIMIT 1",
            (now, path, path)).fetchone()
    return row is not None


def active_permission_grants():
    with _db() as connection:
        rows = connection.execute("SELECT token, grant_type, duration, scope, details_json, created_at, expires_at FROM permission_grants WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC", (time.time(),)).fetchall()
    return [dict(row) for row in rows]


def revoke_permission_grant(token):
    with _db() as connection:
        connection.execute("UPDATE permission_grants SET revoked_at = ? WHERE token = ? AND revoked_at IS NULL", (time.time(), token))
        connection.commit()


def queue_desktop_job(kind, payload):
    if emergency_stop() and kind != "clear_guidance":
        raise PermissionError("Emergency stop is enabled")
    token = secrets.token_urlsafe(18)
    with _db() as connection:
        connection.execute(
            "INSERT INTO desktop_jobs (token, kind, payload_json, created_at, status) VALUES (?, ?, ?, ?, 'pending')",
            (token, kind, json.dumps(payload), time.time()),
        )
    return token


def start_guidance_session(max_duration_seconds=900):
    if emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    duration = max(1, min(int(max_duration_seconds), GUIDANCE_SESSION_TTL))
    token = secrets.token_urlsafe(18)
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, now)
        active = connection.execute("SELECT token FROM guidance_sessions WHERE status = 'active' AND expires_at > ?", (now,)).fetchone()
        if active:
            connection.rollback()
            raise PermissionError("A guidance session is already active")
        connection.execute("INSERT INTO guidance_sessions (token, created_at, expires_at, status) VALUES (?, ?, ?, 'active')", (token, now, now + duration))
        connection.commit()
    return guidance_session_status(token)


def guidance_session_status(token=None):
    with _db() as connection:
        now = time.time()
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("UPDATE guidance_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
        query = "SELECT token, created_at, expires_at, status, last_capture_at FROM guidance_sessions WHERE status = 'active'"
        params = ()
        if token:
            query += " AND token = ?"
            params = (token,)
        query += " ORDER BY created_at DESC LIMIT 1"
        row = connection.execute(query, params).fetchone()
        connection.commit()
    if row is None:
        return {"active": False, "session_id": token}
    return {"active": True, "session_id": row["token"], "created_at": row["created_at"], "expires_at": row["expires_at"], "last_capture_at": row["last_capture_at"]}


def stop_guidance_session(token=None):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        query = "UPDATE guidance_sessions SET status = 'stopped', stopped_at = ? WHERE status = 'active'"
        params = (now,)
        if token:
            query += " AND token = ?"
            params = (now, token)
        updated = connection.execute(query, params).rowcount
        connection.commit()
    return updated > 0


def touch_guidance_capture(token):
    with _db() as connection:
        connection.execute("UPDATE guidance_sessions SET last_capture_at = ? WHERE token = ? AND status = 'active'", (time.time(), token))


def queue_guidance_click(token, display_id, x, y, button="left", modifiers=None, occurred_at=None):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        active = connection.execute("SELECT 1 FROM guidance_sessions WHERE token = ? AND status = 'active' AND expires_at > ?", (token, time.time())).fetchone()
        if active is None:
            connection.rollback()
            return False
        connection.execute("INSERT INTO guidance_click_events (session_token, display_id, x, y, button, modifiers_json, occurred_at) VALUES (?, ?, ?, ?, ?, ?, ?)", (token, int(display_id), float(x), float(y), button, json.dumps(modifiers or []), occurred_at or time.time()))
        connection.commit()
    return True


def get_guidance_clicks(token, consume=True):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute("SELECT id, display_id, x, y, button, modifiers_json, occurred_at FROM guidance_click_events WHERE session_token = ? AND consumed_at IS NULL ORDER BY id", (token,)).fetchall()
        if consume and rows:
            connection.executemany("UPDATE guidance_click_events SET consumed_at = ? WHERE id = ?", [(time.time(), row["id"]) for row in rows])
        connection.commit()
    return [{"event_id": row["id"], "display_id": row["display_id"], "x": row["x"], "y": row["y"], "button": row["button"], "modifiers": json.loads(row["modifiers_json"]), "occurred_at": row["occurred_at"]} for row in rows]


def claim_desktop_jobs():
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        rows = connection.execute(
            "SELECT token, kind, payload_json FROM desktop_jobs WHERE status = 'pending' ORDER BY created_at"
        ).fetchall()
        if rows:
            connection.executemany("UPDATE desktop_jobs SET status = 'claimed' WHERE token = ?", [(row["token"],) for row in rows])
        connection.commit()
    return [{"job_id": row["token"], "kind": row["kind"], "payload": json.loads(row["payload_json"])} for row in rows]


def complete_desktop_job(job_id, result=None, blob=None):
    with _db() as connection:
        connection.execute(
            "UPDATE desktop_jobs SET status = 'complete', result_json = ?, result_blob = ?, completed_at = ? WHERE token = ? AND status = 'claimed'",
            (json.dumps(result or {}), blob, time.time(), job_id),
        )


def desktop_job_result(job_id, consume_blob=False):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute(
            "SELECT status, result_json, result_blob FROM desktop_jobs WHERE token = ?", (job_id,)
        ).fetchone()
        if row is None or row["status"] != "complete":
            connection.commit()
            return None
        result = json.loads(row["result_json"] or "{}")
        if consume_blob:
            blob = row["result_blob"]
            connection.execute("DELETE FROM desktop_jobs WHERE token = ?", (job_id,))
            connection.commit()
            return result, blob
        connection.commit()
    return result


def create_follow_up(title, check_at, expires_at=None, project_session_id=None, metadata=None):
    if not title or len(title) > 240:
        raise ValueError("Follow-up title must be 1-240 characters")
    token = secrets.token_urlsafe(18)
    now = time.time()
    with _db() as connection:
        connection.execute(
            "INSERT INTO follow_ups (token, title, status, check_at, expires_at, project_session, metadata_json, created_at) VALUES (?, ?, 'pending', ?, ?, ?, ?, ?)",
            (token, title, float(check_at), float(expires_at) if expires_at is not None else None, project_session_id, json.dumps(metadata or {}), now),
        )
    return token


def pending_follow_ups(include_future=True):
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("UPDATE follow_ups SET status = 'expired' WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= ?", (now,))
        query = "SELECT token, title, status, check_at, expires_at, project_session, metadata_json, created_at FROM follow_ups WHERE status = 'pending'"
        params = () if include_future else (now,)
        if not include_future:
            query += " AND check_at <= ?"
        query += " ORDER BY check_at"
        rows = connection.execute(query, params).fetchall()
        connection.commit()
    return [
        {"follow_up_id": row["token"], "title": row["title"], "status": row["status"], "check_at": row["check_at"], "expires_at": row["expires_at"], "project_session": row["project_session"], "metadata": json.loads(row["metadata_json"]), "created_at": row["created_at"]}
        for row in rows
    ]


def complete_follow_up(token):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        updated = connection.execute("UPDATE follow_ups SET status = 'completed', completed_at = ? WHERE token = ? AND status = 'pending'", (time.time(), token)).rowcount
        connection.commit()
    if not updated:
        raise PermissionError("Unknown or already completed follow-up")
