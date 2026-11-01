# Path: src/laptop_bridge/command_jobs.py
"""Owned, bounded background coding commands. Output never enters SQLite."""
import os
import signal
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field

from . import state

OUTPUT_LIMIT = 4 * 1024 * 1024
MAX_RUNNING = 4
MAX_CHUNK = 8192
KEEP_SECONDS = 3600


@dataclass
class _Runtime:
    stdout: object = field(default_factory=lambda: tempfile.TemporaryFile(mode="w+b"))
    stderr: object = field(default_factory=lambda: tempfile.TemporaryFile(mode="w+b"))
    process: subprocess.Popen | None = None
    finished_at: float | None = None

    def close(self):
        self.stdout.close()
        self.stderr.close()


def _stop_tree(process):
    if process is None or process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        try:
            process.wait(timeout=0.6)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait(timeout=1)
    except (ProcessLookupError, OSError):
        pass


class CommandJobManager:
    def __init__(self, *, timeout=600, poll=0.1):
        self.timeout = timeout
        self.poll = poll
        self._lock = threading.RLock()
        self._jobs = {}

    def _cleanup(self):
        now = time.time()
        for job_id, runtime in list(self._jobs.items()):
            if runtime.finished_at is not None and now - runtime.finished_at > KEEP_SECONDS:
                runtime.close()
                del self._jobs[job_id]

    def launch(self, job_id, session_id, executable, argv, cwd, environment):
        """The caller MUST consume a matching local command grant before launch."""
        with self._lock:
            self._cleanup()
            if sum(job.finished_at is None for job in self._jobs.values()) >= MAX_RUNNING:
                raise RuntimeError("Maximum four concurrent project commands")
            job = _Runtime()
            self._jobs[job_id] = job
        threading.Thread(
            target=self._run, args=(job_id, session_id, executable, argv, cwd, environment, job),
            daemon=True, name=f"relayos-command-job-{job_id[:8]}",
        ).start()

    def _run(self, job_id, session_id, executable, argv, cwd, environment, job):
        started = time.monotonic()
        reason = None
        process = None
        try:
            metadata = state.command_job(job_id)
            if metadata is None or metadata["cancel_requested"] or state.emergency_stop():
                reason = "cancelled"
                return
            # The session can have been revoked between approval and launch.
            state.project_session(session_id)
            process = subprocess.Popen(
                [executable, *argv[1:]], stdin=subprocess.DEVNULL,
                stdout=job.stdout, stderr=job.stderr, shell=False,
                cwd=cwd, env=environment, start_new_session=(os.name == "posix"),
            )
            with self._lock:
                job.process = process
            state.mark_command_job_running(job_id)
            while process.poll() is None:
                if state.emergency_stop():
                    reason = "emergency_stop"
                elif state.command_job(job_id)["cancel_requested"]:
                    reason = "cancelled"
                else:
                    try:
                        state.project_session(session_id)
                    except PermissionError:
                        reason = "session_expired"
                    if not reason and time.monotonic() - started >= self.timeout:
                        reason = "timeout"
                    if not reason and max(os.fstat(job.stdout.fileno()).st_size,
                                          os.fstat(job.stderr.fileno()).st_size) >= OUTPUT_LIMIT:
                        reason = "output_limit"
                if reason:
                    _stop_tree(process)
                    break
                time.sleep(self.poll)
            process.wait()
        except (OSError, PermissionError, ValueError, RuntimeError) as error:
            reason = reason or ("launch_failed" if isinstance(error, OSError) else "session_expired")
        finally:
            if process is not None and process.poll() is None:
                _stop_tree(process)
            # The UI can activate emergency stop while a child is being
            # spawned or while its exit is being observed. Label such races
            # as cancellation, not an unexplained execution failure.
            if (reason is None or reason in ("launch_failed", "failed")) and state.emergency_stop() and (process is None or process.returncode != 0):
                reason = "emergency_stop"
            status = (
                "cancelled" if reason in ("cancelled", "emergency_stop", "session_expired")
                else "timed_out" if reason == "timeout"
                else "output_limit" if reason == "output_limit"
                else "failed" if reason or (process and process.returncode != 0)
                else "completed"
            )
            size = max(os.fstat(job.stdout.fileno()).st_size, os.fstat(job.stderr.fileno()).st_size)
            state.finish_command_job(job_id, status, exit_code=process.returncode if process else None,
                                     output_bytes=size, reason=reason)
            with self._lock:
                job.finished_at = time.time()

    def output(self, job_id, *, stdout_offset=0, stderr_offset=0):
        for offset in (stdout_offset, stderr_offset):
            if not isinstance(offset, int) or offset < 0 or offset > OUTPUT_LIMIT:
                raise ValueError("Output offset outside 0..4MiB")
        with self._lock:
            self._cleanup()
            runtime = self._jobs.get(job_id)
            if runtime is None:
                return {"stdout": "", "stderr": "", "stdout_offset": stdout_offset,
                        "stderr_offset": stderr_offset, "output_unavailable": True}
            def chunk(file, offset):
                size = os.fstat(file.fileno()).st_size
                data = os.pread(file.fileno(), min(MAX_CHUNK, max(0, size - offset)), offset)
                return data.decode("utf-8", errors="replace"), offset + len(data)
            stdout, next_out = chunk(runtime.stdout, stdout_offset)
            stderr, next_err = chunk(runtime.stderr, stderr_offset)
            return {"stdout": stdout, "stderr": stderr, "stdout_offset": next_out,
                    "stderr_offset": next_err, "output_unavailable": False}


manager = CommandJobManager()
