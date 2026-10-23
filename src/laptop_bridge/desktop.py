"""PySide6 macOS menu-bar companion for local Laptop Bridge approvals, guidance overlay, and coding sessions."""
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QLockFile, QProcess, QTimer, Qt
from PySide6.QtGui import QAction, QFont, QIcon, QGuiApplication
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QHeaderView, QLabel, QMainWindow, QMenu, QMessageBox,
    QPlainTextEdit, QPushButton, QSystemTrayIcon, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import capture, state
from .config import STATE_DIR
from .overlay import GuidanceOverlay
from .input_observer import ClickObserver


class ApprovalDialog(QDialog):
    def __init__(self, request, parent=None):
        super().__init__(parent)
        self.request = request
        self.setWindowTitle("Laptop Bridge approval")
        self.setMinimumWidth(480)
        layout = QFormLayout(self)

        if request["kind"] == "project_session":
            self.setWindowTitle("Laptop Bridge: Project Coding Session Approval")
            kind_label = QLabel("60-Minute Project Coding Session")
            kind_label.setStyleSheet("font-weight: bold; color: #0284c7;")
            layout.addRow("Action", kind_label)
            layout.addRow("Project folder", QLabel(request["target"]))
            info = QLabel(
                "Grants MCP server access to read, list, write, patch, and execute "
                "non-interactive commands strictly inside this folder for 60 minutes.\n"
                "Path containment and symlink escape checks are strictly enforced."
            )
            info.setWordWrap(True)
            layout.addRow("Permission scope", info)
        elif request["kind"] == "oauth_authorization":
            self.setWindowTitle("Laptop Bridge: Gemini Connection Approval")
            kind_label = QLabel("Gemini MCP Connection")
            kind_label.setStyleSheet("font-weight: bold; color: #0284c7;")
            layout.addRow("Action", kind_label)
            layout.addRow("OAuth client", QLabel(request["client_id"]))
            layout.addRow("Google callback", QLabel(request["redirect_uri"]))
            layout.addRow("Scope", QLabel(", ".join(request["scopes"])))
            info = QLabel("Approving lets this Gemini client call Laptop Bridge until the connection is revoked or its 30-day authorization expires.")
            info.setWordWrap(True)
            layout.addRow("Permission scope", info)
        else:
            layout.addRow("Action", QLabel(request["kind"]))
            layout.addRow("Configured target", QLabel(request["target"]))
            argv = QPlainTextEdit(json.dumps(request["argv"], indent=2))
            argv.setReadOnly(True)
            argv.setMinimumHeight(90)
            layout.addRow("Exact command", argv)

        ttl = state.OAUTH_APPROVAL_TTL if request["kind"] == "oauth_authorization" else state.TTL
        layout.addRow("Expires", QLabel(datetime.fromtimestamp(request["created_at"] + ttl).strftime("%Y-%m-%d %H:%M:%S")))

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Cancel | QDialogButtonBox.StandardButton.Ok)
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("Approve")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("Deny")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addRow(buttons)


class StatusWindow(QMainWindow):
    def __init__(self, companion):
        super().__init__()
        self.companion = companion
        self.setWindowTitle("Laptop Bridge")
        self.setMinimumSize(760, 640)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setSpacing(12)

        # 1. Server and Permission Status
        status_box = QVBoxLayout()
        self.status = QLabel()
        self.status.setStyleSheet("font-size: 13px; font-weight: bold;")
        status_box.addWidget(self.status)

        perm_layout = QHBoxLayout()
        self.perm_label = QLabel()
        self.perm_button = QPushButton("Open Screen Recording Settings")
        self.perm_button.clicked.connect(lambda: capture.open_permission_settings("screen"))
        perm_layout.addWidget(self.perm_label)
        perm_layout.addWidget(self.perm_button)
        perm_layout.addStretch()
        status_box.addLayout(perm_layout)

        access_layout = QHBoxLayout()
        self.access_label = QLabel()
        self.access_button = QPushButton("Open Accessibility Settings")
        self.access_button.clicked.connect(lambda: capture.open_permission_settings("accessibility"))
        access_layout.addWidget(self.access_label)
        access_layout.addWidget(self.access_button)
        access_layout.addStretch()
        status_box.addLayout(access_layout)

        # Display sharing / guidance indicator
        self.display_sharing_label = QLabel()
        status_box.addWidget(self.display_sharing_label)

        layout.addLayout(status_box)

        # 2. Emergency Stop
        self.stop = QCheckBox("Emergency stop: block all actions and terminate active coding sessions")
        self.stop.setStyleSheet("font-weight: bold; color: #dc2626;")
        self.stop.toggled.connect(self.companion.set_emergency_stop)
        layout.addWidget(self.stop)

        # 3. Active Coding Sessions Section
        session_header = QHBoxLayout()
        session_title = QLabel("Active Project Coding Sessions (60-minute limit)")
        session_title.setStyleSheet("font-weight: bold; font-size: 12px;")
        session_header.addWidget(session_title)
        session_header.addStretch()
        start_session_btn = QPushButton("New Project Session…")
        start_session_btn.clicked.connect(self.companion.start_project_session_dialog)
        session_header.addWidget(start_session_btn)
        layout.addLayout(session_header)

        self.session_info = QLabel("No active project sessions")
        self.session_info.setStyleSheet("color: #64748b; padding-left: 8px;")
        layout.addWidget(self.session_info)

        grants_title = QLabel("Always-Allowed Commands (until revoked)")
        grants_title.setStyleSheet("font-weight: bold; font-size: 12px;")
        layout.addWidget(grants_title)
        self.grants = QTableWidget(0, 4)
        self.grants.setHorizontalHeaderLabels(["Executable", "Project", "Saved", ""])
        self.grants.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.grants.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.grants.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.grants.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.grants.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.grants.setMaximumHeight(150)
        layout.addWidget(self.grants)

        # 4. Overlay Controls
        overlay_box = QHBoxLayout()
        overlay_title = QLabel("Visual Guidance:")
        overlay_title.setStyleSheet("font-weight: bold;")
        overlay_box.addWidget(overlay_title)

        test_guidance_btn = QPushButton("Demo Guidance")
        test_guidance_btn.clicked.connect(self.companion.demo_guidance)
        overlay_box.addWidget(test_guidance_btn)

        self.clear_guidance_btn = QPushButton("Clear Guidance")
        self.clear_guidance_btn.clicked.connect(self.companion.clear_guidance)
        overlay_box.addWidget(self.clear_guidance_btn)
        overlay_box.addStretch()
        layout.addLayout(overlay_box)

        # 5. Recent Action History
        history_title = QLabel("Recent Action History (metadata only, 30-day retention)")
        history_title.setStyleSheet("font-weight: bold; font-size: 12px;")
        layout.addWidget(history_title)

        self.history = QTableWidget(0, 5)
        self.history.setHorizontalHeaderLabels(["Time", "Action", "Target", "Decision", "Result"])
        self.history.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.history.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        layout.addWidget(self.history)

        self.setCentralWidget(content)

    def refresh(self):
        process = getattr(self.companion, "server", None)
        try:
            running = process is not None and process.state() == QProcess.ProcessState.Running
        except RuntimeError:
            running = False
        detail = "Server: Running at http://127.0.0.1:8765/mcp" if running else "Server: Stopped"
        self.status.setText(detail)

        has_perm = capture.has_screen_recording_permission()
        if has_perm:
            self.perm_label.setText("Screen Recording: Granted")
            self.perm_label.setStyleSheet("color: #16a34a;")
            self.perm_button.setVisible(False)
        else:
            self.perm_label.setText("Screen Recording: Permission Required")
            self.perm_label.setStyleSheet("color: #d97706;")
            self.perm_button.setVisible(True)

        has_access = capture.has_accessibility_permission()
        if has_access:
            self.access_label.setText("Accessibility: Granted")
            self.access_label.setStyleSheet("color: #16a34a;")
            self.access_button.setVisible(False)
        else:
            self.access_label.setText("Accessibility: Permission Required")
            self.access_label.setStyleSheet("color: #d97706;")
            self.access_button.setVisible(True)

        if self.companion.overlay.is_guidance_active():
            self.display_sharing_label.setText(
                f"Display Sharing: Active (Guidance visible on Display {self.companion.overlay.target_display_id})"
            )
            self.display_sharing_label.setStyleSheet("color: #0284c7; font-weight: bold;")
            self.clear_guidance_btn.setEnabled(True)
        else:
            self.display_sharing_label.setText("Display Sharing: Inactive (no overlay visible)")
            self.display_sharing_label.setStyleSheet("color: #64748b;")
            self.clear_guidance_btn.setEnabled(False)

        self.stop.blockSignals(True)
        self.stop.setChecked(state.emergency_stop())
        self.stop.blockSignals(False)

        # Update active project sessions & countdown
        sessions = state.active_project_sessions()
        if sessions:
            now = time.time()
            lines = []
            for s in sessions:
                remaining = max(0, int(s["expires_at"] - now))
                mins, secs = divmod(remaining, 60)
                lines.append(f"• {s['root']}  [{mins}m {secs:02d}s remaining]")
            self.session_info.setText("\n".join(lines))
            self.session_info.setStyleSheet("color: #0369a1; font-weight: 500; padding-left: 8px;")
        else:
            self.session_info.setText("No active project sessions")
            self.session_info.setStyleSheet("color: #64748b; padding-left: 8px;")

        grants = state.saved_command_grants()
        self.grants.setRowCount(len(grants))
        for row_index, grant in enumerate(grants):
            self.grants.setItem(row_index, 0, QTableWidgetItem(grant["executable"]))
            self.grants.setItem(row_index, 1, QTableWidgetItem(grant["project_root"]))
            self.grants.setItem(row_index, 2, QTableWidgetItem(datetime.fromtimestamp(grant["created_at"]).strftime("%Y-%m-%d %H:%M")))
            revoke = QPushButton("Revoke")
            revoke.clicked.connect(lambda _checked=False, token=grant["token"]: self.companion.revoke_command_grant(token))
            self.grants.setCellWidget(row_index, 3, revoke)

        # Update history
        rows = state.recent_history()
        self.history.setRowCount(len(rows))
        for row_index, row in enumerate(rows):
            result = "" if row["exit_code"] is None else str(row["exit_code"])
            values = [
                datetime.fromtimestamp(row["recorded_at"]).strftime("%Y-%m-%d %H:%M:%S"),
                row["kind"],
                row["target"],
                row["decision"],
                result,
            ]
            for column, value in enumerate(values):
                self.history.setItem(row_index, column, QTableWidgetItem(value))


class Companion:
    def __init__(self, app):
        self.app = app
        self.overlay = GuidanceOverlay()
        self.click_observer = ClickObserver(self._record_guidance_click)
        self.guidance_observer_session = None
        self.window = StatusWindow(self)
        self.server = QProcess(self.window)
        self.tunnel = QProcess(self.window)
        self.server.finished.connect(self._server_stopped)
        self.restart_requested = False
        self.pending_dialog = False

        self.tray = QSystemTrayIcon(QIcon.fromTheme("computer"), app)
        menu = QMenu()

        self.status_action = QAction("Server: stopped", menu)
        self.status_action.setEnabled(False)
        menu.addAction(self.status_action)

        self.overlay_status_action = QAction("Overlay: inactive", menu)
        self.overlay_status_action.setEnabled(False)
        menu.addAction(self.overlay_status_action)

        self.guidance_session_action = QAction("Screen sharing: inactive", menu)
        self.guidance_session_action.setEnabled(False)
        menu.addAction(self.guidance_session_action)

        self.session_status_action = QAction("Active session: none", menu)
        self.session_status_action.setEnabled(False)
        menu.addAction(self.session_status_action)

        menu.addSeparator()
        menu.addAction("Start Project Coding Session…", self.start_project_session_dialog)
        menu.addAction("Show Guidance…", self.demo_guidance)
        menu.addAction("Clear Guidance", self.clear_guidance)

        menu.addSeparator()
        menu.addAction("Open Laptop Bridge…", self.show_window)
        menu.addAction("Restart server", self.restart_server)

        menu.addSeparator()
        self.stop_action = QAction("Emergency stop", menu, checkable=True)
        self.stop_action.setChecked(state.emergency_stop())
        self.stop_action.toggled.connect(self.set_emergency_stop)
        menu.addAction(self.stop_action)

        menu.addSeparator()
        menu.addAction("Quit", self.quit)

        self.tray.setContextMenu(menu)
        self.tray.activated.connect(
            lambda reason: self.show_window() if reason == QSystemTrayIcon.ActivationReason.Trigger else None
        )
        self.tray.show()

        # Responsive polling for pending requests and desktop jobs (200ms)
        self.poller = QTimer()
        self.poller.timeout.connect(self.poll)
        self.poller.start(200)

        self.start_server()
        # Show the onboarding/status window on first launch when macOS permissions
        # still need attention; subsequent launches remain tray-first.
        if not capture.has_screen_recording_permission() or not capture.has_accessibility_permission():
            QTimer.singleShot(350, self.show_window)

    def start_server(self):
        if self.server.state() != QProcess.ProcessState.NotRunning:
            return
        if getattr(sys, "frozen", False):
            self.server.start(sys.executable, ["--server"])
        else:
            venv_python = Path(sys.prefix) / "bin" / "python"
            executable = str(venv_python) if venv_python.exists() else sys.executable
            self.server.start(executable, ["-m", "laptop_bridge.server"])
        self.status_action.setText("Server: starting")

    def start_tunnel(self):
        """Start the named Cloudflare tunnel after the local server is ready."""
        if self.tunnel.state() != QProcess.ProcessState.NotRunning:
            return
        config = os.getenv("LAPTOP_BRIDGE_CLOUDFLARE_CONFIG", str(Path.home() / ".cloudflared/config.yml"))
        if not Path(config).is_file():
            return
        self.tunnel.start("cloudflared", ["--config", config, "tunnel", "run"])

    def restart_server(self):
        if self.server.state() == QProcess.ProcessState.NotRunning:
            self.start_server()
        else:
            self.restart_requested = True
            self.server.terminate()

    def _server_stopped(self):
        self.status_action.setText("Server: stopped")
        try:
            self.window.refresh()
        except RuntimeError:
            pass
        if self.restart_requested:
            self.restart_requested = False
            self.start_server()

    def set_emergency_stop(self, enabled):
        state.set_emergency_stop(enabled)
        if enabled:
            self.overlay.clear_guidance()
        self.stop_action.setChecked(enabled)
        self.window.refresh()

    def start_project_session_dialog(self):
        if state.emergency_stop():
            QMessageBox.warning(self.window, "Emergency stop", "Emergency stop is enabled. Disable it before approving new sessions.")
            return
        folder = QFileDialog.getExistingDirectory(self.window, "Select Project Root for 60-Minute Coding Session")
        if not folder:
            return
        folder_path = str(Path(folder).resolve())
        reply = QMessageBox.question(
            self.window,
            "Approve Project Coding Session",
            f"Grant Laptop Bridge MCP server 60-minute read/write/patch/command access strictly inside:\n\n{folder_path}\n\nProceed?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply == QMessageBox.StandardButton.Yes:
            try:
                token = state.create_project_session_request(folder_path)
                state.approve(token)
                session = state.activate_project_session(token)
                self.window.refresh()
                QMessageBox.information(
                    self.window,
                    "Coding Session Active",
                    f"Approved 60-minute coding session for:\n{session['root']}\n\nSession ID: {session['session_id']}",
                )
            except Exception as err:
                QMessageBox.critical(self.window, "Session Error", str(err))

    def demo_guidance(self):
        self.overlay.show_guidance(
            display_id=0,
            x=320,
            y=240,
            label="Laptop Bridge",
            message="Visual guidance active. Mouse trailing enabled.",
            timeout_seconds=15,
        )
        self.window.refresh()

    def clear_guidance(self):
        self.overlay.clear_guidance()
        self.window.refresh()

    def revoke_command_grant(self, token):
        try:
            state.revoke_command_grant(token)
            self.window.refresh()
        except Exception as error:
            QMessageBox.warning(self.window, "Could not revoke grant", str(error))

    def _record_guidance_click(self, x, y, button, modifiers, occurred_at):
        session = state.guidance_session_status(self.guidance_observer_session)
        if not session.get("active"):
            return
        display_id = 0
        for index, screen in enumerate(QGuiApplication.screens()):
            if screen.geometry().contains(int(x), int(y)):
                display_id = index
                break
        state.queue_guidance_click(self.guidance_observer_session, display_id, x, y, button, modifiers, occurred_at)

    def poll(self):
        try:
            running = self.server.state() == QProcess.ProcessState.Running
        except RuntimeError:
            running = False
        self.status_action.setText("Server: running" if running else "Server: stopped")
        if running and self.tunnel.state() == QProcess.ProcessState.NotRunning:
            self.start_tunnel()

        if self.overlay.is_guidance_active():
            self.overlay_status_action.setText(f"Overlay: active (Display {self.overlay.target_display_id})")
        else:
            self.overlay_status_action.setText("Overlay: inactive")

        guidance = state.guidance_session_status()
        if guidance.get("active"):
            remaining = max(0, int(guidance["expires_at"] - time.time()))
            self.guidance_session_action.setText(f"Screen sharing: active ({remaining // 60}m left)")
        else:
            self.guidance_session_action.setText("Screen sharing: inactive")
            if self.guidance_observer_session:
                self.click_observer.stop()
                self.guidance_observer_session = None
        if guidance.get("active") and self.guidance_observer_session != guidance.get("session_id"):
            if self.click_observer.start():
                self.guidance_observer_session = guidance.get("session_id")

        sessions = state.active_project_sessions()
        if sessions:
            remaining = max(0, int(sessions[0]["expires_at"] - time.time()))
            mins = remaining // 60
            self.session_status_action.setText(f"Active session: {mins}m left")
        else:
            self.session_status_action.setText("Active session: none")

        try:
            self.window.refresh()
        except RuntimeError:
            pass

        # Handle queued desktop jobs
        for job in state.claim_desktop_jobs():
            kind = job["kind"]
            payload = job.get("payload", {})
            job_id = job["job_id"]

            if kind == "screen_snapshot":
                try:
                    metadata, png_bytes = capture.capture_snapshot(payload.get("display_id"))
                    if payload.get("session_id"):
                        state.touch_guidance_capture(payload["session_id"])
                    state.complete_desktop_job(job_id, result=metadata, blob=png_bytes)
                except Exception as error:
                    state.complete_desktop_job(job_id, result={"error": str(error)})
            elif kind == "show_guidance":
                try:
                    self.overlay.show_guidance(
                        display_id=payload.get("display_id", 0),
                        x=payload.get("x", 200),
                        y=payload.get("y", 200),
                        label=payload.get("label", "Laptop Bridge"),
                        message=payload.get("message", ""),
                        timeout_seconds=payload.get("timeout_seconds", 15),
                    )
                    state.complete_desktop_job(job_id, result={"status": "displayed"})
                except Exception as error:
                    state.complete_desktop_job(job_id, result={"error": str(error)})
            elif kind == "clear_guidance":
                self.overlay.clear_guidance()
                state.complete_desktop_job(job_id, result={"status": "cleared"})
            elif kind == "stop_guidance_session":
                self.overlay.clear_guidance()
                state.stop_guidance_session(payload.get("session_id"))
                state.complete_desktop_job(job_id, result={"status": "stopped"})

        # Handle pending approval requests
        if self.pending_dialog or state.emergency_stop():
            return
        oauth_pending = state.pending_oauth_authorizations()
        pending = state.pending_requests()
        if not oauth_pending and not pending:
            return
        if oauth_pending:
            self.pending_dialog = True
            dialog = ApprovalDialog({"kind": "oauth_authorization", **oauth_pending[0]}, self.window)
            try:
                state.decide_oauth_authorization(oauth_pending[0]["request_id"], dialog.exec() == QDialog.DialogCode.Accepted)
            except PermissionError as error:
                QMessageBox.warning(self.window, "Approval unavailable", str(error))
            finally:
                self.pending_dialog = False
            return
        # Let ChatGPT's confirmation/approval call complete before showing the
        # local-client fallback dialog for a newly requested folder session.
        if pending[0]["kind"] == "project_session" and time.time() - pending[0]["created_at"] < 15:
            return
        self.pending_dialog = True
        dialog = ApprovalDialog(pending[0], self.window)
        try:
            if dialog.exec() == QDialog.DialogCode.Accepted:
                state.approve(pending[0]["request_id"])
            else:
                state.deny(pending[0]["request_id"])
        except PermissionError as error:
            QMessageBox.warning(self.window, "Approval unavailable", str(error))
        finally:
            self.pending_dialog = False

    def show_window(self):
        self.window.refresh()
        self.window.show()
        self.window.raise_()
        self.window.activateWindow()

    def quit(self):
        self.poller.stop()
        self.overlay.clear_guidance()
        try:
            self.server.finished.disconnect()
        except Exception:
            pass
        try:
            if self.tunnel.state() != QProcess.ProcessState.NotRunning:
                self.tunnel.terminate()
                if not self.tunnel.waitForFinished(1500):
                    self.tunnel.kill()
                    self.tunnel.waitForFinished(500)
        except RuntimeError:
            pass
        try:
            if self.server.state() != QProcess.ProcessState.NotRunning:
                self.server.terminate()
                if not self.server.waitForFinished(2000):
                    self.server.kill()
                    self.server.waitForFinished(1000)
        except RuntimeError:
            pass
        self.app.quit()


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        raise SystemExit("Laptop Bridge requires a system tray")
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = QLockFile(str(STATE_DIR / "desktop-instance.lock"))
    lock.setStaleLockTime(30_000)
    if not lock.tryLock(100):
        # Finder/open repeatedly invokes the bundle; keep one tray companion.
        return
    companion = Companion(app)
    app.companion = companion
    app.instance_lock = lock
    raise SystemExit(app.exec())
