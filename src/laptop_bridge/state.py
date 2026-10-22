"""Transaction-safe local state for approvals and metadata-only auditing."""
import json
import secrets
import sqlite3
import time
from contextlib import contextmanager

from .config import DATABASE_FILE, STATE_DIR

TTL = 300
HISTORY_RETENTION = 30 * 24 * 60 * 60
PROJECT_SESSION_TTL = 60 * 60
JOB_TTL = 30


@contextmanager
def _db():
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    connection = sqlite3.connect(DATABASE_FILE, timeout=5, isolation_level=None)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=5000")
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
                revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS desktop_jobs (
                token TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
                created_at REAL NOT NULL, status TEXT NOT NULL, result_json TEXT,
                result_blob BLOB, completed_at REAL
            );
        """)
        yield connection
    finally:
        connection.close()


def _expire(connection, now):
    connection.execute("UPDATE requests SET status = 'expired', decided_at = ? WHERE status = 'pending' AND created_at < ?", (now, now - TTL))
    connection.execute("UPDATE project_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
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
            connection.execute("UPDATE desktop_jobs SET status = 'cancelled', completed_at = ? WHERE status IN ('pending', 'claimed')", (now,))
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


def _decide(token, status):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire(connection, now)
        row = connection.execute("SELECT kind, target FROM requests WHERE token = ? AND status = 'pending'", (token,)).fetchone()
        if row is None:
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
    item = consume(request_id)
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
            "INSERT INTO project_sessions (token, root, created_at, expires_at, status, decided_at) VALUES (?, ?, ?, ?, 'active', ?)",
            (token, item["details"]["target"], now, now + PROJECT_SESSION_TTL, now),
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
