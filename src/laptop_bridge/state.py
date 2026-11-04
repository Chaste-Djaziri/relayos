"""Transaction-safe local state for approvals and metadata-only auditing."""
import json
import hashlib
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from .config import DATABASE_FILE, STATE_DIR
from .command_policy import reusable_command_family, validate_scope_prefix

TTL = 300
HISTORY_RETENTION = 30 * 24 * 60 * 60
PROJECT_SESSION_TTL = 60 * 60
JOB_TTL = 30
GUIDANCE_SESSION_TTL = 15 * 60
FILE_ACCESS_TTL = 15 * 60
OAUTH_APPROVAL_TTL = 5 * 60
OAUTH_CODE_TTL = 5 * 60
OAUTH_ACCESS_TOKEN_TTL = 60 * 60
OAUTH_REFRESH_TOKEN_TTL = 30 * 24 * 60 * 60


_INITIALIZED_DBS = set()


def normalize_folder_scope(folder):
    """Return a stable folder scope on case-insensitive macOS volumes.

    MCP clients often disagree on `GitHub` versus `github`.  Resolve every
    existing path component against the directory's actual entry name so those
    spellings share one persistent grant instead of producing duplicates.
    """
    candidate = Path(folder).expanduser()
    if not candidate.is_absolute():
        candidate = Path.home() / candidate
    candidate = candidate.resolve(strict=False)
    current = Path(candidate.anchor)
    parts = candidate.parts[1:]
    for index, part in enumerate(parts):
        if current.is_dir():
            try:
                match = next((entry for entry in current.iterdir() if entry.name.casefold() == part.casefold()), None)
            except OSError:
                match = None
            if match is not None:
                current = match
                continue
        current = current.joinpath(*parts[index:])
        break
    return str(current.resolve(strict=False))


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
                    decided_at REAL, consumed_at REAL,
                    context_json TEXT NOT NULL DEFAULT '{}', approved_duration TEXT
                );
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS action_history (
                    id INTEGER PRIMARY KEY, recorded_at REAL NOT NULL, kind TEXT NOT NULL,
                    target TEXT NOT NULL, decision TEXT NOT NULL, exit_code INTEGER, duration_ms INTEGER,
                    detail_json TEXT
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
            CREATE TABLE IF NOT EXISTS file_access_sessions (
                token TEXT PRIMARY KEY, root TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL NOT NULL, revoked_at REAL
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
            CREATE TABLE IF NOT EXISTS command_jobs (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, project_root TEXT NOT NULL,
                working_directory TEXT NOT NULL, executable_name TEXT NOT NULL,
                status TEXT NOT NULL, created_at REAL NOT NULL, finished_at REAL,
                exit_code INTEGER, output_bytes INTEGER NOT NULL DEFAULT 0,
                error_reason TEXT, cancel_requested INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS command_jobs_created ON command_jobs(created_at DESC);
            CREATE TABLE IF NOT EXISTS command_grants (
                token TEXT PRIMARY KEY, project_root TEXT NOT NULL,
                executable TEXT NOT NULL, argv_digest TEXT,
                working_directory TEXT, grant_type TEXT NOT NULL,
                created_at REAL NOT NULL, expires_at REAL,
                revoked_at REAL, family_key TEXT, session_token TEXT, prefix_json TEXT
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
            # Migrate authorization metadata without broadening any legacy approval.
            grant_columns = {row["name"] for row in connection.execute("PRAGMA table_info(command_grants)")}
            if "family_key" not in grant_columns:
                connection.execute("ALTER TABLE command_grants ADD COLUMN family_key TEXT")
            if "session_token" not in grant_columns:
                connection.execute("ALTER TABLE command_grants ADD COLUMN session_token TEXT")
            if "prefix_json" not in grant_columns:
                connection.execute("ALTER TABLE command_grants ADD COLUMN prefix_json TEXT")
            # Old session grants were time-limited but not bound to an actual
            # project-session token: revoke these rather than guessing scope.
            connection.execute(
                "UPDATE command_grants SET revoked_at = ? WHERE grant_type = 'session' AND session_token IS NULL AND revoked_at IS NULL",
                (time.time(),),
            )
            columns = {row["name"] for row in connection.execute("PRAGMA table_info(requests)")}
            if "context_json" not in columns:
                connection.execute("ALTER TABLE requests ADD COLUMN context_json TEXT NOT NULL DEFAULT '{}'")
            if "approved_duration" not in columns:
                connection.execute("ALTER TABLE requests ADD COLUMN approved_duration TEXT")
            action_columns = {row["name"] for row in connection.execute("PRAGMA table_info(action_history)")}
            if "detail_json" not in action_columns:
                connection.execute("ALTER TABLE action_history ADD COLUMN detail_json TEXT")
            # Family grants intentionally store NULL argv_digest. Only recognized
            # families are valid; do not treat them as legacy executable-wide
            # grants during initialization in a separate approval-helper process.
            connection.execute("""
                UPDATE command_grants SET revoked_at = ?
                WHERE revoked_at IS NULL AND (
                    working_directory IS NULL
                    OR (
                        argv_digest IS NULL AND (
                            (family_key IS NULL AND prefix_json IS NULL) OR (family_key IS NOT NULL AND family_key NOT IN ('git:add'))
                            OR grant_type NOT IN ('session', 'always')
                        )
                    )
                )
            """, (time.time(),))
            connection.execute("CREATE INDEX IF NOT EXISTS command_grants_lookup ON command_grants(project_root, executable, grant_type, revoked_at)")
            connection.execute("CREATE INDEX IF NOT EXISTS permission_grants_scope ON permission_grants(grant_type, scope, revoked_at)")
            connection.execute("CREATE INDEX IF NOT EXISTS oauth_tokens_lookup ON oauth_tokens(token_digest, token_type, revoked_at)")
            # Rewrite grants made before path normalization, then deduplicate.
            # On default macOS volumes GitHub and github are the same folder,
            # but SQLite string comparison treated them as separate grants.
            old_scopes = connection.execute(
                "SELECT token, scope FROM permission_grants WHERE grant_type = 'folder' AND revoked_at IS NULL"
            ).fetchall()
            for row in old_scopes:
                scope = normalize_folder_scope(row["scope"])
                if scope != row["scope"]:
                    connection.execute(
                        "UPDATE permission_grants SET scope = ?, details_json = ? WHERE token = ?",
                        (scope, json.dumps({"folder": scope}), row["token"]),
                    )
            # Older companions inserted a new persistent row each time a user
            # chose "always allow" for the same folder. Keep one canonical
            # live grant per scope and mark redundant rows revoked.
            connection.execute("""
                UPDATE permission_grants SET revoked_at = ? WHERE token IN (
                    SELECT token FROM (
                        SELECT token, ROW_NUMBER() OVER (
                            PARTITION BY grant_type, scope ORDER BY created_at DESC
                        ) AS duplicate_rank
                        FROM permission_grants
                        WHERE revoked_at IS NULL
                    ) WHERE duplicate_rank > 1
                )
            """, (time.time(),))
            _INITIALIZED_DBS.add(db_path)
            try:
                connection.execute("ALTER TABLE project_sessions ADD COLUMN request_id TEXT")
            except sqlite3.OperationalError:
                pass
        yield connection
    finally:
        connection.close()


def _expire(connection, now):
    expired = connection.execute(
        "SELECT kind, target FROM requests WHERE status = 'pending' AND created_at < ?",
        (now - TTL,),
    ).fetchall()
    connection.execute("UPDATE requests SET status = 'expired', decided_at = ? WHERE status = 'pending' AND created_at < ?", (now, now - TTL))
    for row in expired:
        _record(connection, row["kind"], row["target"], "expired")
    connection.execute("UPDATE project_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
    connection.execute("UPDATE guidance_sessions SET status = 'expired' WHERE status = 'active' AND expires_at <= ?", (now,))
    connection.execute("DELETE FROM file_access_sessions WHERE expires_at <= ?", (now,))
    connection.execute("DELETE FROM desktop_jobs WHERE created_at < ?", (now - JOB_TTL,))


def _record(connection, kind, target, decision, exit_code=None, duration_ms=None, detail=None):
    now = time.time()
    detail_json = None
    if detail is not None:
        if isinstance(detail, (dict, list)):
            detail_json = json.dumps(detail)
        else:
            detail_json = str(detail)
    connection.execute(
        "INSERT INTO action_history (recorded_at, kind, target, decision, exit_code, duration_ms, detail_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (now, kind, target, decision, exit_code, duration_ms, detail_json),
    )
    connection.execute("DELETE FROM action_history WHERE recorded_at < ?", (now - HISTORY_RETENTION,))


def request(kind, details):
    token = secrets.token_urlsafe(18)
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        connection.execute(
            "INSERT INTO requests (token, kind, target, argv_json, created_at, status, context_json) VALUES (?, ?, ?, ?, ?, 'pending', ?)",
            (token, kind, details["target"], json.dumps(details["argv"]), time.time(), json.dumps(details.get("context", {}), sort_keys=True)),
        )
        _record(connection, kind, details["target"], "requested")
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
            connection.execute("UPDATE file_access_sessions SET revoked_at = ? WHERE revoked_at IS NULL", (now,))
            connection.execute("UPDATE desktop_jobs SET status = 'cancelled', completed_at = ? WHERE status IN ('pending', 'claimed')", (now,))
            connection.execute("UPDATE oauth_tokens SET revoked_at = ? WHERE revoked_at IS NULL", (now,))
            connection.execute("UPDATE oauth_authorizations SET status = 'denied', decided_at = ? WHERE status = 'pending'", (now,))
            connection.execute("UPDATE requests SET status = 'denied', decided_at = ? WHERE status = 'pending'", (now,))
            connection.execute("UPDATE command_grants SET revoked_at = ? WHERE revoked_at IS NULL", (now,))
        connection.commit()
    if enabled:
        # Emergency Stop immediately revokes temporary screenshot links,
        # including if it is switched off before their natural expiry.
        from .screenshot_links import store
        store.revoke_all()
        from . import cursor_guidance, screen_capture, walkthrough
        cursor_guidance.clear()
        screen_capture.revoke_sharing()
        walkthrough.revoke()
        from . import guidance_workspace, guided_lesson, screen_annotations
        guided_lesson.revoke()
        guidance_workspace.revoke()
        screen_annotations.revoke()


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


def _split_command_target(target, cwd=None):
    if cwd and target.startswith(f"{cwd}:"):
        return str(cwd), target[len(cwd) + 1:]
    if ":/" in target:
        root, exe = target.split(":/", 1)
        return root, "/" + exe
    if ":" in target:
        return target.split(":", 1)
    return None, None


def decide_request(token, duration="once", confirmation=None):
    """Record a LOCAL user's choice; no approval can expand it later."""
    if duration not in {"once", "session", "persistent", "deny"}:
        raise ValueError("duration must be once, session, persistent, or deny")
    with _db() as connection:
        row = connection.execute(
            "SELECT kind, target, argv_json, context_json, status FROM requests WHERE token = ?", (token,)
        ).fetchone()
    if row is None or row["status"] != "pending":
        return False
    # A screenshot request is never reusable, even if a generic client
    # submits a Session/Always choice to the local approval helper.
    if row["kind"] in {"screen_capture", "storage_scan", "file_access", "file_operation", "empty_trash"} and duration not in {"once", "deny"}:
        raise ValueError("This sensitive action requires Approve Once or Deny")
    if row["kind"] == "empty_trash" and duration == "once" and confirmation != "EMPTY TRASH":
        raise PermissionError("Locally type EMPTY TRASH to authorize permanent deletion")
    if duration == "deny":
        _decide(token, "denied")
        return True
    _decide(token, "approved", duration, confirmation=confirmation)
    if row["kind"] == "project_session":
        if duration == "persistent":
            grant_folder(row["target"], "persistent")
        activate_project_session(token)
    elif row["kind"] == "project_command" and duration in {"session", "persistent"}:
        argv = json.loads(row["argv_json"] or "[]")
        context = json.loads(row["context_json"] or "{}")
        cwd = context.get("cwd")
        project_root, executable = _split_command_target(row["target"], cwd)
        session_id = context.get("session_id")
        if project_root and executable and cwd and argv and (duration == "persistent" or session_id):
            grant_type = "always" if duration == "persistent" else "session"
            try:
                grant_project_command(
                    project_root, executable, argv, cwd, grant_type,
                    session_id=session_id, scope_prefix=context.get("scope_prefix"),
                )
            except (ValueError, PermissionError):
                pass
    return True


def _decide(token, status, duration="once", confirmation=None):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        now = time.time()
        _expire(connection, now)
        row = connection.execute("SELECT kind, target, status, argv_json, context_json FROM requests WHERE token = ?", (token,)).fetchone()
        if row is not None and status == "approved" and row["status"] == "approved":
            connection.commit()
            return
        if row is None or row["status"] != "pending":
            connection.rollback()
            raise PermissionError("Unknown, expired, or already decided request")
        if status == "approved" and emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop prevents approving requests")
        context = json.loads(row["context_json"] or "{}")
        if row["kind"] == "empty_trash" and status == "approved":
            if confirmation != "EMPTY TRASH":
                connection.rollback()
                raise PermissionError("Locally type EMPTY TRASH before approval")
            context["typed_local_confirmation"] = True
        connection.execute(
            "UPDATE requests SET status = ?, decided_at = ?, approved_duration = ?, context_json = ? WHERE token = ?",
            (status, now, duration if status == "approved" else None,
             json.dumps(context), token),
        )
        _record(connection, row["kind"], row["target"], status)
        connection.commit()


def consume(token, expected_kind=None):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        _expire(connection, now)
        row = connection.execute("SELECT kind, target, argv_json, context_json, approved_duration FROM requests WHERE token = ? AND status = 'approved' AND created_at >= ?", (token, now - TTL)).fetchone()
        if row is None or (expected_kind is not None and row["kind"] != expected_kind):
            connection.rollback()
            raise PermissionError("Missing, expired, or incorrectly scoped approval")
        connection.execute("UPDATE requests SET status = 'consumed', consumed_at = ? WHERE token = ?", (now, token))
        connection.commit()
    if row["kind"] == "empty_trash" and not json.loads(row["context_json"] or "{}").get("typed_local_confirmation"):
        raise PermissionError("Missing the typed local Empty Trash confirmation")
    return {"kind": row["kind"], "details": {"target": row["target"], "argv": json.loads(row["argv_json"]), "context": json.loads(row["context_json"] or "{}")}, "approved_duration": row["approved_duration"] or "once"}


def record_result(kind, target, exit_code=None, duration_ms=None, detail=None):
    with _db() as connection:
        _record(connection, kind, target, "executed", exit_code, duration_ms, detail=detail)


def pending_requests():
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, time.time())
        rows = connection.execute("SELECT token, kind, target, argv_json, context_json, created_at FROM requests WHERE status = 'pending' ORDER BY created_at").fetchall()
        connection.commit()
    return [{"request_id": row["token"], "kind": row["kind"], "target": row["target"], "argv": json.loads(row["argv_json"]), "context": json.loads(row["context_json"] or "{}"), "created_at": row["created_at"]} for row in rows]


def approval_inbox():
    """Locally view all pending project/permission and OAuth approvals together.

    Raw command argv is returned only over the local helper, never to a public
    MCP tool. OAuth redirect URIs are excluded to avoid exposing credentials.
    """
    requests = pending_requests()
    oauth = pending_oauth_authorizations()
    result = []
    for item in requests:
        result.append({
            "request_id": item["request_id"], "kind": item["kind"],
            "target": item["target"], "argv": item["argv"],
            "context": item["context"], "created_at": item["created_at"],
            "expires_at": item["created_at"] + TTL,
        })
    for item in oauth:
        result.append({
            "request_id": item["request_id"], "kind": "oauth_connection",
            "target": item["client_name"], "argv": [],
            "context": {"client_id": item["client_id"]},
            "created_at": item["created_at"],
            "expires_at": item["created_at"] + OAUTH_APPROVAL_TTL,
        })
    return sorted(result, key=lambda item: (item["created_at"], item["request_id"]))


def decide_inbox_request(request_id, decision, confirmation=None):
    """One local inbox entry, one deliberate decision; fail closed on stale IDs."""
    if decision not in {"once", "session", "persistent", "deny"}:
        raise ValueError("Invalid inbox decision")
    with _db() as connection:
        row = connection.execute(
            "SELECT kind, status FROM requests WHERE token = ?", (request_id,)
        ).fetchone()
        oauth = connection.execute(
            "SELECT status FROM oauth_authorizations WHERE token = ?", (request_id,)
        ).fetchone() if row is None else None
    if row is not None:
        if not decide_request(request_id, decision, confirmation=confirmation):
            raise PermissionError("Request was already decided or expired")
        return {"request_id": request_id, "kind": row["kind"], "decision": decision}
    if oauth is not None:
        if decision not in {"once", "deny"}:
            raise ValueError("OAuth connections support Approve once or Deny only")
        decide_oauth_authorization(request_id, decision == "once")
        return {"request_id": request_id, "kind": "oauth_connection", "decision": decision}
    raise PermissionError("Unknown inbox request")


def approval_activity(limit=100, search=""):
    """Persisted, detailed audit entries, bounded and searchable."""
    limit = max(1, min(int(limit), 300))
    with _db() as connection:
        clauses = ""
        values = []
        if search:
            clauses = " WHERE (instr(lower(kind), lower(?)) > 0 OR instr(lower(target), lower(?)) > 0 OR instr(lower(decision), lower(?)) > 0 OR instr(lower(coalesce(detail_json, '')), lower(?)) > 0)"
            values = [search[:120]] * 4
        rows = connection.execute(
            """SELECT id, recorded_at, kind, target, decision, exit_code, duration_ms, detail_json
               FROM action_history""" + clauses +
            " ORDER BY recorded_at DESC, id DESC LIMIT ?",
            (*values, limit),
        ).fetchall()
    return [dict(row) for row in rows]


def create_command_job(session_id, project_root, cwd, executable_name, argv=None):
    job_id = secrets.token_urlsafe(18)
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        connection.execute(
            """INSERT INTO command_jobs
               (id, session_id, project_root, working_directory, executable_name, status, created_at)
               VALUES (?, ?, ?, ?, ?, 'queued', ?)""",
            (job_id, session_id, project_root, cwd, executable_name, now),
        )
        cmd_str = " ".join(argv) if argv else executable_name
        target = f"{project_root}:{cmd_str}"
        detail = {
            "argv": argv or [executable_name],
            "command": cmd_str,
            "working_directory": cwd,
            "executable": executable_name,
            "job_id": job_id,
        }
        _record(connection, "command_job", target, "queued", detail=detail)
        connection.commit()
    return job_id


def command_job(job_id, session_id=None):
    with _db() as connection:
        where = "id = ?" if session_id is None else "id = ? AND session_id = ?"
        values = (job_id,) if session_id is None else (job_id, session_id)
        row = connection.execute(
            """SELECT id, session_id, project_root, working_directory, executable_name,
                      status, created_at, finished_at, exit_code, output_bytes,
                      error_reason, cancel_requested
               FROM command_jobs WHERE """ + where, values
        ).fetchone()
    return dict(row) if row else None


def list_command_jobs(session_id=None, limit=50):
    limit = max(1, min(int(limit), 100))
    with _db() as connection:
        if session_id is None:
            rows = connection.execute(
                """SELECT * FROM command_jobs ORDER BY created_at DESC LIMIT ?""",
                (limit,),
            ).fetchall()
        else:
            rows = connection.execute(
                """SELECT * FROM command_jobs WHERE session_id = ?
                   ORDER BY created_at DESC LIMIT ?""", (session_id, limit)
            ).fetchall()
    return [dict(row) for row in rows]


def request_command_job_cancel(job_id, session_id=None):
    """Local UI can cancel any job; MCP clients must pass their session ID."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        where = "id = ?" if session_id is None else "id = ? AND session_id = ?"
        args = (job_id,) if session_id is None else (job_id, session_id)
        row = connection.execute(
            "SELECT status FROM command_jobs WHERE " + where, args
        ).fetchone()
        if row is None:
            connection.rollback()
            raise PermissionError("Unknown command job or session")
        if row["status"] in ("queued", "running"):
            connection.execute(
                "UPDATE command_jobs SET cancel_requested = 1 WHERE " + where, args
            )
        connection.commit()
    return True


def finish_command_job(job_id, status, exit_code=None, output_bytes=0, reason=None):
    if status not in {"completed", "failed", "cancelled", "timed_out", "output_limit", "interrupted"}:
        raise ValueError("Invalid terminal job status")
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute(
            "SELECT project_root, status FROM command_jobs WHERE id = ?", (job_id,)
        ).fetchone()
        if row and row["status"] in ("queued", "running"):
            connection.execute(
                """UPDATE command_jobs SET status = ?, finished_at = ?, exit_code = ?,
                   output_bytes = ?, error_reason = ? WHERE id = ?""",
                (status, time.time(), exit_code, output_bytes, reason, job_id),
            )
            _record(connection, "command_job", row["project_root"], status, exit_code)
        connection.commit()


def mark_command_job_running(job_id):
    with _db() as connection:
        connection.execute(
            """UPDATE command_jobs SET status = 'running' WHERE id = ?
               AND status = 'queued'""", (job_id,),
        )


def interrupt_orphan_command_jobs():
    """Startup recovery: never claim a dead server's subprocess is active."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute(
            "SELECT id, project_root FROM command_jobs WHERE status IN ('queued', 'running')"
        ).fetchall()
        for row in rows:
            connection.execute(
                """UPDATE command_jobs SET status = 'interrupted', finished_at = ?,
                   error_reason = 'server_restarted' WHERE id = ?""",
                (time.time(), row["id"]),
            )
            _record(connection, "command_job", row["project_root"], "interrupted")
        connection.commit()
    return len(rows)


def recent_history(limit=100):
    with _db() as connection:
        rows = connection.execute("SELECT recorded_at, kind, target, decision, exit_code, duration_ms, detail_json FROM action_history ORDER BY recorded_at DESC LIMIT ?", (limit,)).fetchall()
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
            row = connection.execute("SELECT status FROM requests WHERE token = ?", (request_id,)).fetchone()
            if row and row["status"] == "pending":
                raise PermissionError("Project session has not been approved locally. Please approve the request in the RelayOS companion app or via laptop-bridge-approvals.")
            if row and row["status"] == "denied":
                raise PermissionError("Project session request was denied locally.")
        raise
    if item["kind"] != "project_session":
        raise PermissionError("Request is not a project-session approval")
    root = Path(item["details"]["target"])
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise PermissionError(f"Could not create approved project root: {error}") from error
    if not root.is_dir():
        raise PermissionError("Approved project root is not a directory")
    root = root.resolve(strict=True)
    token = secrets.token_urlsafe(18)
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        connection.execute(
            "INSERT INTO project_sessions (token, root, created_at, expires_at, status, decided_at, request_id) VALUES (?, ?, ?, ?, 'active', ?, ?)",
            (token, str(root), now, now + PROJECT_SESSION_TTL, now, request_id),
        )
        _record(connection, "project_session", str(root), "approved")
        connection.commit()
    return {"session_id": token, "root": str(root), "expires_at": now + PROJECT_SESSION_TTL}


def activate_granted_project_session(root):
    """Create or reuse a session directly when an exact persistent folder grant exists."""
    root = Path(root).expanduser().resolve(strict=False)
    if emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    if not folder_granted(root):
        raise PermissionError("Folder does not have a persistent permission grant")
    root.mkdir(parents=True, exist_ok=True)
    root = root.resolve(strict=True)
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        _expire(connection, now)
        existing = connection.execute(
            "SELECT token FROM project_sessions WHERE root = ? AND status = 'active' AND expires_at > ? AND request_id IS NULL ORDER BY created_at DESC LIMIT 1",
            (str(root), now),
        ).fetchone()
        if existing:
            token = existing["token"]
            connection.execute(
                "UPDATE project_sessions SET expires_at = ? WHERE token = ?",
                (now + PROJECT_SESSION_TTL, token),
            )
            _record(connection, "project_session", str(root), "persistent_grant_reused")
            connection.commit()
            return {"session_id": token, "root": str(root), "expires_at": now + PROJECT_SESSION_TTL}
        token = secrets.token_urlsafe(18)
        connection.execute(
            "INSERT INTO project_sessions (token, root, created_at, expires_at, status, decided_at, request_id) VALUES (?, ?, ?, ?, 'active', ?, NULL)",
            (token, str(root), now, now + PROJECT_SESSION_TTL, now),
        )
        _record(connection, "project_session", str(root), "persistent_grant_reused")
        connection.commit()
    return {"session_id": token, "root": str(root), "expires_at": now + PROJECT_SESSION_TTL}


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


def _oauth_audit_name(connection, client_id):
    row = connection.execute(
        "SELECT metadata_json FROM oauth_clients WHERE client_id = ?", (client_id,)
    ).fetchone()
    metadata = json.loads(row["metadata_json"] or "{}") if row else {}
    return str(metadata.get("client_name") or client_id)[:120]


def _expire_oauth(connection, now):
    expired = connection.execute(
        "SELECT client_id FROM oauth_authorizations WHERE status = 'pending' AND created_at < ?",
        (now - OAUTH_APPROVAL_TTL,),
    ).fetchall()
    connection.execute(
        "UPDATE oauth_authorizations SET status = 'expired', decided_at = ? WHERE status = 'pending' AND created_at < ?",
        (now, now - OAUTH_APPROVAL_TTL),
    )
    for row in expired:
        _record(connection, "oauth_authorization", _oauth_audit_name(connection, row["client_id"]), "expired")
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
        _record(connection, "oauth_authorization", _oauth_audit_name(connection, client_id), "requested")
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
        row = connection.execute("SELECT status, client_id FROM oauth_authorizations WHERE token = ?", (request_id,)).fetchone()
        if row is None or row["status"] != "pending":
            connection.rollback()
            raise PermissionError("Unknown, expired, or already decided OAuth authorization")
        if approved and emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop prevents approving OAuth connections")
        connection.execute(
            "UPDATE oauth_authorizations SET status = ?, decided_at = ? WHERE token = ?",
            ("approved" if approved else "denied", now, request_id),
        )
        _record(connection, "oauth_authorization", _oauth_audit_name(connection, row["client_id"]), "approved" if approved else "denied")
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


def _command_context(cwd, grant, session_id=None, family_key=None, scope_prefix=None):
    """Bind a pending approval to its original session and exact command."""
    context = {"cwd": str(cwd), "requested_grant": grant}
    if session_id is not None:
        context["session_id"] = session_id
    if family_key is not None:
        context["command_family"] = family_key
    if scope_prefix is not None:
        context["scope_prefix"] = scope_prefix
    return json.dumps(context, sort_keys=True)


def find_approved_command_request(project_root, executable, argv, cwd, grant, request_id=None, session_id=None, scope_prefix=None):
    target = f"{project_root}:{executable}"
    scope_prefix = validate_scope_prefix(executable, argv, scope_prefix)
    family = reusable_command_family(executable, argv) if scope_prefix is None else None
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, now)
        criteria = (target, json.dumps(argv), _command_context(cwd, grant, session_id, family, scope_prefix))
        if request_id:
            row = connection.execute(
                """SELECT token, status FROM requests WHERE token = ? AND kind = 'project_command'
                   AND target = ? AND argv_json = ? AND context_json = ? AND created_at >= ?""",
                (request_id, *criteria, now - TTL),
            ).fetchone()
            if row and row["status"] == "denied":
                connection.commit()
                raise PermissionError("Command authorization request was denied locally")
            connection.commit()
            return row["token"] if row and row["status"] == "approved" else None
        row = connection.execute(
            """SELECT token FROM requests WHERE kind = 'project_command' AND target = ?
               AND argv_json = ? AND context_json = ? AND status = 'approved'
               AND created_at >= ? ORDER BY created_at DESC LIMIT 1""",
            (*criteria, now - TTL),
        ).fetchone()
        if row is None and request_id is None:
            candidates = connection.execute(
                """SELECT token, context_json FROM requests
                   WHERE kind = 'project_command' AND target = ? AND argv_json = ?
                   AND status = 'approved' AND created_at >= ?
                   ORDER BY created_at DESC""",
                (target, json.dumps(argv), now - TTL),
            ).fetchall()
            for candidate in candidates:
                ctx = json.loads(candidate["context_json"] or "{}")
                if (
                    ctx.get("cwd") == str(cwd)
                    and ctx.get("requested_grant") == grant
                    and ctx.get("command_family") == family
                    and ctx.get("scope_prefix") == scope_prefix
                ):
                    row = candidate
                    break
        connection.commit()
        return row["token"] if row else None


def get_or_create_command_request(project_root, executable, argv, cwd, grant, session_id=None, scope_prefix=None):
    target = f"{project_root}:{executable}"
    scope_prefix = validate_scope_prefix(executable, argv, scope_prefix)
    family = reusable_command_family(executable, argv) if scope_prefix is None else None
    context = {"cwd": str(cwd), "requested_grant": grant}
    if session_id is not None:
        context["session_id"] = session_id
    if family is not None:
        context["command_family"] = family
    if scope_prefix is not None:
        context["scope_prefix"] = scope_prefix
    now = time.time()
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        _expire(connection, now)
        row = connection.execute(
            """SELECT token FROM requests WHERE kind = 'project_command' AND target = ?
               AND argv_json = ? AND context_json = ? AND status = 'pending'
               AND created_at >= ? ORDER BY created_at DESC LIMIT 1""",
            (target, json.dumps(argv), _command_context(cwd, grant, session_id, family, scope_prefix), now - TTL),
        ).fetchone()
        connection.commit()
        if row:
            return row["token"]
    return request("project_command", {"target": target, "argv": argv, "context": context})


def grant_project_command(project_root, executable, argv, cwd, grant_type="once", session_id=None, scope_prefix=None):
    """Store local choice: exact once; exact/family reusable within same cwd/root."""
    if grant_type not in {"once", "session", "always"}:
        raise ValueError("grant_type must be once, session, or always")
    if grant_type == "session" and not session_id:
        raise ValueError("Session grants require the approved coding session ID")
    if emergency_stop():
        raise PermissionError("Emergency stop is enabled")
    token = secrets.token_urlsafe(24)
    now = time.time()
    scope_prefix = validate_scope_prefix(executable, argv, scope_prefix)
    prefix = scope_prefix if grant_type != "once" else None
    family = reusable_command_family(executable, argv) if grant_type != "once" and prefix is None else None
    digest = None if family is not None or prefix is not None else _command_digest(argv, cwd)
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        # Duplicate local approvals must not inflate the permissions list.
        # Only reuse a token when *every* part of its effective scope matches.
        # Once grants remain fresh single-use tokens.
        if grant_type != "once":
            existing = connection.execute(
                """SELECT token FROM command_grants
                   WHERE project_root = ? AND executable = ? AND working_directory = ?
                     AND grant_type = ? AND session_token IS ?
                     AND argv_digest IS ? AND family_key IS ? AND prefix_json IS ?
                     AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)
                   ORDER BY created_at DESC LIMIT 1""",
                (project_root, executable, cwd, grant_type,
                 session_id if grant_type == "session" else None, digest, family,
                 json.dumps(prefix) if prefix is not None else None, now),
            ).fetchone()
            if existing:
                connection.commit()
                return existing["token"]
        connection.execute(
            """INSERT INTO command_grants
               (token, project_root, executable, argv_digest, working_directory, grant_type,
                created_at, expires_at, family_key, session_token, prefix_json)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (token, project_root, executable, digest, cwd, grant_type,
             now, now + 300 if grant_type == "once" else now + 3600 if grant_type == "session" else None,
             family, session_id if grant_type == "session" else None,
             json.dumps(prefix) if prefix is not None else None),
        )
        _record(connection, "command_grant", f"{project_root}:{executable}", f"approved_{grant_type}")
        connection.commit()
    return token


def _reusable_command_grant(connection, project_root, executable, argv, cwd, session_id, now):
    """Match only exact argv, legacy allowlisted family, or explicit literal prefix."""
    family = reusable_command_family(executable, argv)
    rows = connection.execute(
        """SELECT token, grant_type, family_key, prefix_json, argv_digest FROM command_grants
           WHERE project_root = ? AND executable = ? AND working_directory = ?
           AND grant_type IN ('session', 'always')
           AND (grant_type = 'always' OR (grant_type = 'session' AND session_token = ?))
           AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)
           ORDER BY created_at DESC""",
        (project_root, executable, cwd, session_id, now),
    ).fetchall()
    digest = _command_digest(argv, cwd)
    for row in rows:
        if row["prefix_json"] is not None:
            try:
                prefix = json.loads(row["prefix_json"])
                if validate_scope_prefix(executable, argv, prefix) is None:
                    continue
            except (ValueError, TypeError):
                continue
            return row
        if row["family_key"] is not None:
            if row["family_key"] == family:
                return row
        elif row["argv_digest"] is not None and row["argv_digest"] == digest:
            return row
    return None


def has_saved_command_grant(project_root, executable, argv, cwd, session_id=None):
    with _db() as connection:
        if emergency_stop(connection):
            return False
        return _reusable_command_grant(connection, project_root, executable, argv, cwd, session_id, time.time()) is not None


def _consume_approved_command_request(connection, project_root, executable, argv, cwd, grant_token, session_id, now):
    target = f"{project_root}:{executable}"
    _expire(connection, now)
    if grant_token:
        rows = connection.execute(
            """SELECT token, argv_json, context_json, approved_duration
               FROM requests WHERE token = ? AND kind = 'project_command'
               AND target = ? AND status = 'approved' AND created_at >= ?""",
            (grant_token, target, now - TTL),
        ).fetchall()
    else:
        rows = connection.execute(
            """SELECT token, argv_json, context_json, approved_duration
               FROM requests WHERE kind = 'project_command' AND target = ?
               AND status = 'approved' AND created_at >= ?
               ORDER BY created_at DESC""",
            (target, now - TTL),
        ).fetchall()
    for row in rows:
        try:
            req_argv = json.loads(row["argv_json"] or "[]")
            ctx = json.loads(row["context_json"] or "{}")
        except (ValueError, TypeError):
            continue
        if ctx.get("cwd") != str(cwd):
            continue
        duration = row["approved_duration"] or "once"
        req_session = ctx.get("session_id")
        if duration == "once":
            if req_argv != argv:
                continue
            connection.execute(
                "UPDATE requests SET status = 'consumed', consumed_at = ? WHERE token = ?",
                (now, row["token"]),
            )
            return "approved_once"
        if duration in {"session", "persistent"}:
            if duration == "session" and req_session and session_id and req_session != session_id:
                continue
            prefix = ctx.get("scope_prefix")
            family = ctx.get("command_family")
            matched = False
            if prefix is not None:
                try:
                    matched = validate_scope_prefix(executable, argv, prefix) is not None
                except (ValueError, TypeError):
                    matched = False
            elif family is not None:
                matched = reusable_command_family(executable, argv) == family
            else:
                matched = req_argv == argv
            if not matched:
                continue
            connection.execute(
                "UPDATE requests SET status = 'consumed', consumed_at = ? WHERE token = ?",
                (now, row["token"]),
            )
            return "approved_reusable"
    return None


def consume_project_command_grant(project_root, executable, argv, cwd, grant_token=None, session_id=None):
    """Atomically validate an exact one-use token or a locally chosen reusable scope."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        if emergency_stop(connection):
            connection.rollback()
            raise PermissionError("Emergency stop is enabled")
        now = time.time()
        if grant_token:
            row = connection.execute(
                """SELECT token FROM command_grants WHERE token = ? AND project_root = ?
                   AND executable = ? AND argv_digest = ? AND working_directory = ?
                   AND family_key IS NULL AND grant_type = 'once'
                   AND revoked_at IS NULL AND expires_at > ?""",
                (grant_token, project_root, executable, _command_digest(argv, cwd), cwd, now),
            ).fetchone()
            if row is not None:
                connection.execute("DELETE FROM command_grants WHERE token = ?", (grant_token,))
                connection.commit()
                return "approved_once"
            direct = _consume_approved_command_request(
                connection, project_root, executable, argv, cwd, grant_token, session_id, now
            )
            if direct is not None:
                connection.commit()
                return direct
            connection.rollback()
            raise PermissionError("Missing, expired, mismatched, or already-used command approval")
        row = _reusable_command_grant(connection, project_root, executable, argv, cwd, session_id, now)
        if row is not None:
            connection.commit()
            return "approved_reusable"
        direct = _consume_approved_command_request(
            connection, project_root, executable, argv, cwd, None, session_id, now
        )
        if direct is not None:
            connection.commit()
            return direct
        connection.rollback()
        raise PermissionError("Command approval required for this project and command scope")

def _live_command_grants(connection, now):
    return connection.execute(
        """SELECT token, project_root, executable, grant_type, family_key,
                  prefix_json, argv_digest, session_token, working_directory,
                  created_at, expires_at
           FROM command_grants
           WHERE grant_type IN ('always', 'session') AND revoked_at IS NULL
             AND (expires_at IS NULL OR expires_at > ?)
           ORDER BY created_at DESC, token DESC""",
        (now,),
    ).fetchall()


def _grant_identity(row):
    """Exact effective scope; never merge different commands or sessions."""
    return (
        row["project_root"], row["executable"], row["working_directory"],
        row["grant_type"], row["session_token"],
        row["argv_digest"], row["family_key"], row["prefix_json"],
    )


def _duplicate_command_grant_tokens(rows):
    seen = set()
    redundant = []
    for row in rows:
        # Invalid legacy wildcard grants are not valid permissions to merge.
        if not (row["argv_digest"] or row["family_key"] or row["prefix_json"]):
            continue
        identity = _grant_identity(row)
        if identity in seen:
            redundant.append(row["token"])
        else:
            seen.add(identity)
    return redundant


def command_grant_duplicate_summary():
    """Read-only preview; does not reveal command arguments or secret tokens."""
    with _db() as connection:
        rows = _live_command_grants(connection, time.time())
        redundant = _duplicate_command_grant_tokens(rows)
    return {"total": len(rows), "duplicates": len(redundant)}


def cleanup_duplicate_command_grants():
    """Locally invoked action only; preserve the newest grant per exact scope."""
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        redundant = _duplicate_command_grant_tokens(_live_command_grants(connection, time.time()))
        if redundant:
            connection.executemany(
                "UPDATE command_grants SET revoked_at = ? WHERE token = ? AND revoked_at IS NULL",
                [(time.time(), token) for token in redundant],
            )
            _record(connection, "command_grant_cleanup", "local", f"removed_{len(redundant)}")
        connection.commit()
    return {"removed": len(redundant)}


def saved_command_grants():
    with _db() as connection:
        rows = _live_command_grants(connection, time.time())
    # A short digest fingerprint differentiates legacy exact scopes without
    # retaining or disclosing the original command line (which may hold secrets).
    result = []
    for row in rows:
        data = dict(row)
        data["scope_prefix"] = json.loads(data["prefix_json"]) if data["prefix_json"] else None
        data["scope_fingerprint"] = data["argv_digest"][:10] if data["argv_digest"] else None
        data.pop("argv_digest")
        data.pop("session_token")
        result.append(data)
    return result

def revoke_command_grant(token):
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            "UPDATE command_grants SET revoked_at = ? WHERE token = ? AND grant_type IN ('always', 'session') AND revoked_at IS NULL",
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
    scope = normalize_folder_scope(folder)
    token = secrets.token_urlsafe(24); now = time.time()
    with _db() as connection:
        connection.execute(
            "UPDATE permission_grants SET revoked_at = ? WHERE grant_type = 'folder' AND scope = ? AND revoked_at IS NULL",
            (now, scope),
        )
        connection.execute("INSERT INTO permission_grants VALUES (?, 'folder', ?, ?, ?, ?, NULL, NULL)",
                           (token, duration, scope, json.dumps({"folder": scope}), now))
        connection.commit()
    return token


def folder_granted(folder):
    path = normalize_folder_scope(folder)
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

def create_file_access_session(folder):
    """Issue a short-lived metadata/operation session after a consumed local grant."""
    token = secrets.token_urlsafe(24)
    now = time.time()
    with _db() as db:
        db.execute("BEGIN IMMEDIATE")
        if emergency_stop(db):
            raise PermissionError("Emergency stop is enabled")
        db.execute("INSERT INTO file_access_sessions VALUES (?, ?, ?, ?, NULL)",
                   (token, str(folder), now, now + FILE_ACCESS_TTL))
        db.commit()
    return {"session_id": token, "root": str(folder), "expires_at": now + FILE_ACCESS_TTL,
            "access": "scoped_file_manager", "expires_in_seconds": FILE_ACCESS_TTL}


def file_access_session(token):
    """Resolve an active exact-root session; Emergency Stop revokes all."""
    if not isinstance(token, str) or not 12 <= len(token) <= 256:
        raise PermissionError("Invalid file manager session")
    with _db() as db:
        if emergency_stop(db):
            raise PermissionError("Emergency stop is enabled")
        row = db.execute("SELECT root, expires_at FROM file_access_sessions "
                         "WHERE token = ? AND revoked_at IS NULL AND expires_at > ?",
                         (token, time.time())).fetchone()
    if not row:
        raise PermissionError("File manager session expired, revoked, or missing")
    return {"root": row["root"], "expires_at": row["expires_at"]}


def revoke_file_access_session(token):
    with _db() as db:
        db.execute("UPDATE file_access_sessions SET revoked_at = ? "
                   "WHERE token = ? AND revoked_at IS NULL", (time.time(), token))
