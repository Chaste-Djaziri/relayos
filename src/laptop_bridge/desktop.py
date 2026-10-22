"""PySide6 macOS menu-bar companion for local Laptop Bridge approvals, guidance overlay, and coding sessions."""
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QLockFile, QProcess, QTimer, Qt
from PySide6.QtGui import QAction, QFont, QIcon
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QHeaderView, QLabel, QMainWindow, QMenu, QMessageBox,
    QPlainTextEdit, QPushButton, QSystemTrayIcon, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import capture, state
from .config import STATE_DIR
from .overlay import GuidanceOverlay


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
        else:
            layout.addRow("Action", QLabel(request["kind"]))
            layout.addRow("Configured target", QLabel(request["target"]))
            argv = QPlainTextEdit(json.dumps(request["argv"], indent=2))
            argv.setReadOnly(True)
            argv.setMinimumHeight(90)
            layout.addRow("Exact command", argv)

        layout.addRow(
            "Expires",
            QLabel(datetime.fromtimestamp(request["created_at"] + state.TTL).strftime("%Y-%m-%d %H:%M:%S")),
        )

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
        self.setMinimumSize(680, 520)

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
        venv_python = Path(sys.prefix) / "bin" / "python"
        executable = str(venv_python) if venv_python.exists() else sys.executable
        self.server.start(executable, ["-m", "laptop_bridge.server"])
        self.status_action.setText("Server: starting")

    def start_tunnel(self):
        """Start the configured Secure MCP Tunnel after the local server is ready."""
        if self.tunnel.state() != QProcess.ProcessState.NotRunning:
            return
        script = os.getenv("LAPTOP_BRIDGE_TUNNEL_SCRIPT", str(Path.home() / ".config/laptop-bridge/start-openai-tunnel.zsh"))
        if not Path(script).is_file():
            return
        self.tunnel.start("/bin/zsh", [script])

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

        # Handle pending approval requests
        if self.pending_dialog or state.emergency_stop():
            return
        pending = state.pending_requests()
        if not pending:
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
