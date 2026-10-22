"""PySide6 macOS menu-bar companion for local Laptop Bridge approvals."""
import json
import sys
from datetime import datetime

from PySide6.QtCore import QProcess, QTimer, Qt
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFormLayout, QLabel,
    QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QSystemTrayIcon,
    QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import state


class ApprovalDialog(QDialog):
    def __init__(self, request, parent=None):
        super().__init__(parent)
        self.request = request
        self.setWindowTitle("Laptop Bridge approval")
        layout = QFormLayout(self)
        layout.addRow("Action", QLabel(request["kind"]))
        layout.addRow("Configured target", QLabel(request["target"]))
        argv = QPlainTextEdit(json.dumps(request["argv"], indent=2))
        argv.setReadOnly(True)
        argv.setMinimumHeight(90)
        layout.addRow("Exact command", argv)
        layout.addRow("Expires", QLabel(datetime.fromtimestamp(request["created_at"] + state.TTL).strftime("%Y-%m-%d %H:%M:%S")))
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
        content = QWidget()
        layout = QVBoxLayout(content)
        self.status = QLabel()
        self.stop = QCheckBox("Emergency stop: block all new and approved sensitive actions")
        self.stop.toggled.connect(state.set_emergency_stop)
        self.history = QTableWidget(0, 5)
        self.history.setHorizontalHeaderLabels(["Time", "Action", "Target", "Decision", "Result"])
        self.history.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        layout.addWidget(self.status)
        layout.addWidget(self.stop)
        layout.addWidget(QLabel("Recent action history (metadata only)"))
        layout.addWidget(self.history)
        self.setCentralWidget(content)

    def refresh(self):
        process = self.companion.server
        running = process.state() == QProcess.ProcessState.Running
        detail = "Running at http://127.0.0.1:8765/mcp" if running else "Server is not running"
        self.status.setText(detail)
        self.stop.blockSignals(True)
        self.stop.setChecked(state.emergency_stop())
        self.stop.blockSignals(False)
        rows = state.recent_history()
        self.history.setRowCount(len(rows))
        for row_index, row in enumerate(rows):
            result = "" if row["exit_code"] is None else str(row["exit_code"])
            values = [datetime.fromtimestamp(row["recorded_at"]).strftime("%Y-%m-%d %H:%M:%S"), row["kind"], row["target"], row["decision"], result]
            for column, value in enumerate(values):
                self.history.setItem(row_index, column, QTableWidgetItem(value))
        self.history.resizeColumnsToContents()


class Companion:
    def __init__(self, app):
        self.app = app
        self.server = QProcess()
        self.server.finished.connect(self._server_stopped)
        self.pending_dialog = False
        self.window = StatusWindow(self)
        self.tray = QSystemTrayIcon(QIcon.fromTheme("computer"), app)
        menu = QMenu()
        self.status_action = QAction("Server: stopped", menu)
        self.status_action.setEnabled(False)
        menu.addAction(self.status_action)
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
        self.tray.activated.connect(lambda reason: self.show_window() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        self.tray.show()
        self.poller = QTimer()
        self.poller.timeout.connect(self.poll)
        self.poller.start(750)
        self.start_server()

    def start_server(self):
        if self.server.state() != QProcess.ProcessState.NotRunning:
            return
        self.server.start(sys.executable, ["-m", "laptop_bridge.server"])
        self.status_action.setText("Server: starting")

    def restart_server(self):
        if self.server.state() == QProcess.ProcessState.NotRunning:
            self.start_server()
        else:
            self.server.finished.connect(self.start_server)
            self.server.terminate()

    def _server_stopped(self):
        self.status_action.setText("Server: stopped")
        self.window.refresh()

    def set_emergency_stop(self, enabled):
        state.set_emergency_stop(enabled)
        self.stop_action.setChecked(enabled)
        self.window.refresh()

    def poll(self):
        running = self.server.state() == QProcess.ProcessState.Running
        self.status_action.setText("Server: running" if running else "Server: stopped")
        self.window.refresh()
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
        if self.server.state() != QProcess.ProcessState.NotRunning:
            self.server.terminate()
            self.server.waitForFinished(3000)
            if self.server.state() != QProcess.ProcessState.NotRunning:
                self.server.kill()
        self.app.quit()


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        raise SystemExit("Laptop Bridge requires a system tray")
    Companion(app)
    raise SystemExit(app.exec())
