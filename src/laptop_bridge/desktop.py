"""PySide6 desktop companion for local Laptop Bridge approvals and guidance."""
import json
import os
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QLockFile, QProcess, QTimer, Qt, QUrl
from PySide6.QtGui import QAction, QFont, QIcon, QGuiApplication, QDesktopServices
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QHeaderView, QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox,
    QPlainTextEdit, QPushButton, QSystemTrayIcon, QTableWidget, QTableWidgetItem,
    QTabWidget, QVBoxLayout, QWidget, QWizard, QWizardPage, QGroupBox, QDialog,
)

from . import capture, state, ngrok
from .config import STATE_DIR, load_config, update_config
from . import keychain
from .overlay import GuidanceOverlay
from .input_observer import ClickObserver


def _is_windows():
    return os.name == "nt"


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
            self.setWindowTitle("Laptop Bridge: MCP Connection Approval")
            kind_label = QLabel("MCP Connection")
            kind_label.setStyleSheet("font-weight: bold; color: #0284c7;")
            layout.addRow("Action", kind_label)
            layout.addRow("OAuth client", QLabel(request["client_id"]))
            layout.addRow("Google callback", QLabel(request["redirect_uri"]))
            layout.addRow("Scope", QLabel(", ".join(request["scopes"])))
            info = QLabel("Approving lets this MCP client call Laptop Bridge until the connection is revoked or its 30-day authorization expires.")
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


class OnboardingWizard(QWizard):
    """Small, self-contained provisioning flow for a fresh installation."""
    def __init__(self, companion, parent=None):
        super().__init__(parent)
        self.companion = companion
        self.setWindowTitle("Set up Laptop Bridge")
        self.setMinimumSize(620, 480)

        welcome = QWizardPage(); welcome.setTitle("Your private bridge")
        wl = QVBoxLayout(welcome)
        credential_store = "Windows Credential Manager" if _is_windows() else "macOS Keychain"
        wl.addWidget(QLabel(f"RelayOS runs a local MCP server and gives you a private HTTPS link for ChatGPT, Claude, Gemini, and other MCP clients.\n\nNo shared keys are shipped: this setup creates your own ngrok endpoint and stores secrets in {credential_store}."))
        self.addPage(welcome)

        cf = QWizardPage(); cf.setTitle("Connect ngrok")
        form = QFormLayout(cf)
        self.token = QLineEdit(); self.token.setEchoMode(QLineEdit.EchoMode.Password)
        self.hostname = QLineEdit(); self.hostname.setPlaceholderText("mcp.example.com")
        form.addRow("ngrok authtoken", self.token)
        form.addRow("Reserved domain", self.hostname)
        help_label = QLabel(f"Create an authtoken in the ngrok dashboard and reserve a stable domain such as bridge.ngrok.app. The token is stored only in {credential_store} and never written to the config file.")
        help_label.setWordWrap(True); form.addRow(help_label)
        install_ngrok = QPushButton("Install ngrok with winget" if _is_windows() else "Install ngrok with Homebrew")
        install_ngrok.setToolTip("Runs: winget install ngrok.ngrok" if _is_windows() else "Runs: brew install ngrok/ngrok/ngrok")
        install_ngrok.clicked.connect(self.install_ngrok)
        form.addRow(install_ngrok)
        self.addPage(cf)

        caps = QWizardPage(); caps.setTitle("Choose capabilities")
        cl = QVBoxLayout(caps)
        cl.addWidget(QLabel("Start with the smallest tool set. You can change these choices later by rerunning setup."))
        self.system_status = QCheckBox("System status (recommended)"); self.system_status.setChecked(True); self.system_status.setEnabled(False)
        permission_text = "Screen guidance (Windows privacy settings may restrict capture)" if _is_windows() else "Screen guidance (requires Screen Recording and Accessibility permission)"
        self.screen_guidance = QCheckBox(permission_text)
        self.project_tools = QCheckBox("Project tools (requires an approved project folder for each session)")
        for box in (self.system_status, self.screen_guidance, self.project_tools): cl.addWidget(box)
        cl.addStretch(); self.addPage(caps)

        connect = QWizardPage(); connect.setTitle("Connect your clients")
        vl = QVBoxLayout(connect)
        self.endpoint_preview = QLabel("Your MCP endpoint will appear here")
        self.endpoint_preview.setStyleSheet("font-weight: bold; color: #2563eb;")
        vl.addWidget(QLabel("ChatGPT, Claude, and Gemini use OAuth. After setup, paste the endpoint below into each app; the first connection will ask you to approve it on this Mac."))
        vl.addWidget(self.endpoint_preview); vl.addStretch(); self.addPage(connect)
        self.hostname.textChanged.connect(lambda value: self.endpoint_preview.setText(f"https://{value.strip().strip('/')}/mcp" if value.strip() else "Your MCP endpoint will appear here"))

    def install_ngrok(self):
        if _is_windows():
            if shutil.which("winget"):
                if QProcess.startDetached("winget", ["install", "--id", "ngrok.ngrok", "--exact", "--accept-source-agreements", "--accept-package-agreements"]):
                    QMessageBox.information(self, "Installing ngrok", "winget is installing ngrok in the background. Return to this step when it finishes, then restart Laptop Bridge if ngrok is not found yet.")
                else:
                    QMessageBox.warning(self, "Could not start winget", "Run `winget install ngrok.ngrok` in PowerShell, then return here.")
            else:
                QDesktopServices.openUrl(QUrl("https://ngrok.com/download"))
                QMessageBox.information(self, "Download ngrok", "winget was not found, so the official ngrok download page was opened. Install ngrok, then return here.")
            return
        if not Path("/opt/homebrew/bin/brew").exists() and not Path("/usr/local/bin/brew").exists():
            QMessageBox.warning(self, "Homebrew not found", "Install Homebrew from brew.sh, then return here to install ngrok.")
            return
        brew = "/opt/homebrew/bin/brew" if Path("/opt/homebrew/bin/brew").exists() else "/usr/local/bin/brew"
        if QProcess.startDetached(brew, ["install", "ngrok/ngrok/ngrok"]):
            QMessageBox.information(self, "Installing ngrok", "Homebrew is installing ngrok in the background. Return to this step when it finishes.")
        else:
            QMessageBox.warning(self, "Could not start Homebrew", "Laptop Bridge could not start Homebrew. Run `brew install ngrok/ngrok/ngrok` in Terminal.")

    def accept(self):
        token = self.token.text().strip(); hostname = self.hostname.text().strip().removeprefix("https://").removeprefix("http://").strip("/")
        if not token:
            QMessageBox.warning(self, "ngrok details needed", "Enter your ngrok authtoken.")
            return
        try:
            self.setEnabled(False)
            hostname = ngrok.validate_domain(hostname)
            if not ngrok.find_executable():
                raise ngrok.NgrokError("ngrok was not found. Install it from ngrok.com/download")
            keychain.set_secret("ngrok_authtoken", token)
            config = load_config()
            config.update({"public_base_url": ngrok.endpoint_url(hostname), "active_transport": "ngrok", "setup_complete": True,
                "capabilities": {"system_status": True, "screen_guidance": self.screen_guidance.isChecked(), "project_tools": self.project_tools.isChecked()},
                "ngrok": {"enabled": True, "domain": hostname, "region": "", "config_path": "", "agent_version": ""}})
            update_config(**config)
            self.companion.restart_server()
        except Exception as error:
            QMessageBox.critical(self, "ngrok setup failed", str(error))
            self.setEnabled(True)
            return
        super().accept()


class QuickPanel(QDialog):
    """Compact menu-bar surface; detailed controls remain in Settings."""
    def __init__(self, companion):
        super().__init__(companion.window)
        self.companion = companion
        self.setWindowTitle("Laptop Bridge")
        self.setFixedSize(390, 520)
        self.setWindowFlags(Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint)
        self.setStyleSheet("""
            QDialog { background: #171b25; color: #f8fafc; border: 1px solid #3b4354; border-radius: 18px; }
            QLabel#muted { color: #94a3b8; }
            QGroupBox { background: #222735; border: 1px solid #343c4d; border-radius: 14px; margin-top: 10px; padding: 12px; }
            QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 5px; color: #cbd5e1; }
            QPushButton { background: #303849; border: 1px solid #465168; border-radius: 9px; padding: 8px 12px; color: #f8fafc; }
            QPushButton:hover { background: #3b82f6; }
        """)
        root = QVBoxLayout(self); root.setContentsMargins(18, 18, 18, 18); root.setSpacing(12)
        brand = QHBoxLayout()
        logo = QLabel("◉"); logo.setStyleSheet("font-size: 26px; color: #60a5fa;")
        brand.addWidget(logo)
        title_box = QVBoxLayout(); title = QLabel("Laptop Bridge"); title.setStyleSheet("font-size: 18px; font-weight: 700;")
        self.status = QLabel("Checking status…"); self.status.setObjectName("muted")
        title_box.addWidget(title); title_box.addWidget(self.status); brand.addLayout(title_box); brand.addStretch(); root.addLayout(brand)
        self.endpoint = QLabel(); self.endpoint.setObjectName("muted"); self.endpoint.setWordWrap(True); root.addWidget(self.endpoint)
        connections = QGroupBox("Connections")
        cl = QVBoxLayout(connections)
        for name in ("ChatGPT", "Gemini"):
            row = QHBoxLayout(); label = QLabel(name); label.setStyleSheet("font-weight: 600;"); row.addWidget(label); row.addStretch()
            state_label = QLabel("OAuth ready"); state_label.setObjectName("muted"); row.addWidget(state_label)
            if name == "Gemini":
                self.gemini_state = state_label
                disconnect = QPushButton("Disconnect")
                disconnect.clicked.connect(self.disconnect_gemini)
                row.addWidget(disconnect)
            cl.addLayout(row)
        connect = QPushButton("Copy MCP endpoint")
        connect.clicked.connect(self.copy_endpoint)
        cl.addWidget(connect); root.addWidget(connections)
        stop = QCheckBox("Emergency stop")
        stop.setStyleSheet("color: #fca5a5; font-weight: 600;")
        stop.toggled.connect(companion.set_emergency_stop); self.stop = stop; root.addWidget(stop)
        root.addStretch()
        buttons = QHBoxLayout(); settings = QPushButton("⚙  Settings"); settings.clicked.connect(self.open_settings); quit_btn = QPushButton("Quit"); quit_btn.clicked.connect(companion.quit); buttons.addWidget(settings); buttons.addWidget(quit_btn); root.addLayout(buttons)

    def copy_endpoint(self):
        endpoint = f"{load_config().get('public_base_url', '').rstrip('/')}/mcp"
        QApplication.clipboard().setText(endpoint)
        self.endpoint.setText(f"Copied: {endpoint}")

    def open_settings(self):
        self.close(); self.companion.show_window()

    def refresh(self):
        config = load_config(); public = config.get("public_base_url", "").rstrip("/")
        running = self.companion.server.state() == QProcess.ProcessState.Running
        self.status.setText("Running locally" if running else "Server stopped")
        self.endpoint.setText(f"{public}/mcp" if public else "Setup required")
        self.stop.blockSignals(True); self.stop.setChecked(state.emergency_stop()); self.stop.blockSignals(False)
        grants = state.active_oauth_grants(); self.gemini_state.setText(f"Connected · {len(grants)} grant" if grants else "OAuth ready")

    def disconnect_gemini(self):
        grants = state.active_oauth_grants()
        if not grants:
            return
        self.companion.revoke_oauth_grant(grants[0]["grant_id"])
        self.refresh()


class StatusWindow(QMainWindow):
    def __init__(self, companion):
        super().__init__()
        self.companion = companion
        self.setWindowTitle("Laptop Bridge")
        self.setMinimumSize(760, 640)

        content = QWidget()
        root = QVBoxLayout(content)
        root.setContentsMargins(18, 18, 18, 18)
        root.setSpacing(14)
        header = QHBoxLayout()
        title = QLabel("Laptop Bridge")
        title.setStyleSheet("font-size: 22px; font-weight: 700;")
        header.addWidget(title)
        header.addStretch()
        setup_btn = QPushButton("Setup / Reconfigure")
        setup_btn.clicked.connect(self.companion.open_onboarding)
        header.addWidget(setup_btn)
        root.addLayout(header)
        subtitle = QLabel("Private MCP access for ChatGPT and Gemini")
        subtitle.setStyleSheet("color: #64748b;")
        root.addWidget(subtitle)
        tabs = QTabWidget()
        tabs.setDocumentMode(True)
        root.addWidget(tabs)

        overview = QWidget()
        layout = QVBoxLayout(overview)
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

        oauth_title = QLabel("Connected MCP Clients (30-day refresh authorization)")
        oauth_title.setStyleSheet("font-weight: bold; font-size: 12px;")
        layout.addWidget(oauth_title)
        self.oauth_grants = QTableWidget(0, 3)
        self.oauth_grants.setHorizontalHeaderLabels(["OAuth client", "Authorized", ""])
        self.oauth_grants.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.oauth_grants.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.oauth_grants.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.oauth_grants.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.oauth_grants.setMaximumHeight(120)
        layout.addWidget(self.oauth_grants)

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

        tabs.addTab(overview, "Overview")

        access = QWidget()
        access_layout = QVBoxLayout(access)
        access_layout.setSpacing(12)
        capabilities = QGroupBox("Capabilities")
        cap_layout = QVBoxLayout(capabilities)
        cap_layout.addWidget(QLabel("Only enabled capabilities are advertised to MCP clients. Changes apply after restarting the server."))
        self.cap_screen = QCheckBox("Screen guidance")
        self.cap_project = QCheckBox("Project tools")
        cap_layout.addWidget(self.cap_screen)
        cap_layout.addWidget(self.cap_project)
        save_caps = QPushButton("Save capability settings")
        save_caps.clicked.connect(self.save_capabilities)
        cap_layout.addWidget(save_caps)
        access_layout.addWidget(capabilities)
        permissions = QGroupBox("macOS permissions")
        perm_layout = QVBoxLayout(permissions)
        perm_layout.addWidget(self.perm_label)
        perm_layout.addWidget(self.perm_button)
        perm_layout.addWidget(self.access_label)
        perm_layout.addWidget(self.access_button)
        perm_layout.addWidget(self.display_sharing_label)
        access_layout.addWidget(permissions)
        access_layout.addStretch()
        tabs.addTab(access, "Access")

        settings = QWidget()
        settings_layout = QVBoxLayout(settings)
        endpoint_box = QGroupBox("Connection settings")
        endpoint_layout = QVBoxLayout(endpoint_box)
        self.endpoint_value = QLabel()
        self.endpoint_value.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        endpoint_layout.addWidget(QLabel("Public MCP endpoint"))
        endpoint_layout.addWidget(self.endpoint_value)
        endpoint_layout.addWidget(QLabel("MCP clients use OAuth. Re-run setup to change the reserved domain or ngrok route."))
        settings_layout.addWidget(endpoint_box)
        actions = QGroupBox("Maintenance")
        actions_layout = QHBoxLayout(actions)
        restart_btn = QPushButton("Restart server")
        restart_btn.clicked.connect(self.companion.restart_server)
        stop_btn = QPushButton("Emergency stop")
        stop_btn.clicked.connect(lambda: self.companion.set_emergency_stop(True))
        actions_layout.addWidget(restart_btn)
        actions_layout.addWidget(stop_btn)
        settings_layout.addWidget(actions)
        settings_layout.addStretch()
        tabs.addTab(settings, "Settings")
        self.setCentralWidget(content)

    def save_capabilities(self):
        config = load_config()
        config["capabilities"] = {"system_status": True, "screen_guidance": self.cap_screen.isChecked(), "project_tools": self.cap_project.isChecked()}
        update_config(**config)
        self.companion.restart_server()
        QMessageBox.information(self, "Settings saved", "Capability settings saved and the MCP server is restarting.")

    def refresh(self):
        process = getattr(self.companion, "server", None)
        try:
            running = process is not None and process.state() == QProcess.ProcessState.Running
        except RuntimeError:
            running = False
        config = load_config()
        public = config.get("public_base_url", "").rstrip("/")
        endpoint = f" · Public MCP: {public}/mcp" if public else " · Public MCP: Not configured"
        detail = ("Server: Running at http://127.0.0.1:8765/mcp" if running else "Server: Stopped") + endpoint
        self.status.setText(detail)
        self.endpoint_value.setText(f"{public}/mcp" if public else "Not configured — open Setup / Reconfigure")
        capabilities = config.get("capabilities", {})
        self.cap_screen.setChecked(bool(capabilities.get("screen_guidance")))
        self.cap_project.setChecked(bool(capabilities.get("project_tools")))

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

        oauth_grants = state.active_oauth_grants()
        self.oauth_grants.setRowCount(len(oauth_grants))
        for row_index, grant in enumerate(oauth_grants):
            self.oauth_grants.setItem(row_index, 0, QTableWidgetItem(grant["client_id"]))
            self.oauth_grants.setItem(row_index, 1, QTableWidgetItem(datetime.fromtimestamp(grant["created_at"]).strftime("%Y-%m-%d %H:%M")))
            revoke = QPushButton("Disconnect")
            revoke.clicked.connect(lambda _checked=False, token=grant["grant_id"]: self.companion.revoke_oauth_grant(token))
            self.oauth_grants.setCellWidget(row_index, 2, revoke)

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
        self.quick_panel = None
        self.server = QProcess(self.window)
        self.tunnel = QProcess(self.window)
        self.server.finished.connect(self._server_stopped)
        self.restart_requested = False
        self.pending_dialog = False
        self._shutting_down = False
        self.tray = None
        self.status_action = None
        self.overlay_status_action = None
        self.guidance_session_action = None
        self.session_status_action = None
        self.stop_action = None

        if not _is_windows():
            self._create_tray()

        # Responsive polling for pending requests and desktop jobs (200ms)
        self.poller = QTimer()
        self.poller.timeout.connect(self.poll)
        self.poller.start(200)

        self.start_server()
        if _is_windows():
            self.show_window()
        if not load_config().get("setup_complete"):
            QTimer.singleShot(500, self.open_onboarding)
        # Subsequent macOS launches remain tray-first unless permission needs
        # attention; Windows always keeps controls in its main window.
        if not _is_windows() and (not capture.has_screen_recording_permission() or not capture.has_accessibility_permission()):
            QTimer.singleShot(350, self.show_window)

    def _create_tray(self):
        self.quick_panel = QuickPanel(self)
        self.tray = QSystemTrayIcon(QIcon.fromTheme("computer"), self.app)
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
        menu.addAction("Set up or reconfigure…", self.open_onboarding)
        menu.addAction("Restart server", self.restart_server)

        menu.addSeparator()
        self.stop_action = QAction("Emergency stop", menu, checkable=True)
        self.stop_action.setChecked(state.emergency_stop())
        self.stop_action.toggled.connect(self.set_emergency_stop)
        menu.addAction(self.stop_action)

        menu.addSeparator()
        menu.addAction("Quit", self.quit)

        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._tray_activated)
        self.tray.show()

    def start_server(self):
        if self.server.state() != QProcess.ProcessState.NotRunning:
            return
        if getattr(sys, "frozen", False):
            self.server.start(sys.executable, ["--server"])
        else:
            venv_python = Path(sys.prefix) / "bin" / "python"
            executable = str(venv_python) if venv_python.exists() else sys.executable
            self.server.start(executable, ["-m", "laptop_bridge.server"])
        if self.status_action:
            self.status_action.setText("Server: starting")

    def start_tunnel(self):
        """Start the configured ngrok agent after the local server is ready."""
        if self.tunnel.state() != QProcess.ProcessState.NotRunning:
            return
        config = load_config()
        if config.get("active_transport") != "ngrok" or not config.get("ngrok", {}).get("enabled"):
            return
        try:
            spec = ngrok.process_spec(config["ngrok"]["domain"], keychain.get_secret("ngrok_authtoken") or "")
        except ngrok.NgrokError:
            return
        environment = QProcess.systemEnvironment()
        environment = [entry for entry in environment if not entry.startswith("NGROK_AUTHTOKEN=")]
        environment.append(f"NGROK_AUTHTOKEN={spec['environment']['NGROK_AUTHTOKEN']}")
        self.tunnel.setEnvironment(environment)
        self.tunnel.start(spec["executable"], spec["arguments"])

    def open_onboarding(self):
        wizard = OnboardingWizard(self, self.window)
        wizard.exec()
        self.window.refresh()

    def restart_server(self):
        if self.server.state() == QProcess.ProcessState.NotRunning:
            self.start_server()
        else:
            self.restart_requested = True
            self.server.terminate()

    def _server_stopped(self):
        if self.status_action:
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
        if self.stop_action:
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

    def revoke_oauth_grant(self, grant_id):
        state.revoke_oauth_grant(grant_id)
        self.window.refresh()

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
        if self.status_action:
            self.status_action.setText("Server: running" if running else "Server: stopped")
        if running and self.tunnel.state() == QProcess.ProcessState.NotRunning:
            self.start_tunnel()

        if self.overlay_status_action:
            if self.overlay.is_guidance_active():
                self.overlay_status_action.setText(f"Overlay: active (Display {self.overlay.target_display_id})")
            else:
                self.overlay_status_action.setText("Overlay: inactive")

        guidance = state.guidance_session_status()
        if guidance.get("active"):
            remaining = max(0, int(guidance["expires_at"] - time.time()))
            if self.guidance_session_action:
                self.guidance_session_action.setText(f"Screen sharing: active ({remaining // 60}m left)")
        else:
            if self.guidance_session_action:
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
            if self.session_status_action:
                self.session_status_action.setText(f"Active session: {mins}m left")
        else:
            if self.session_status_action:
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

    def _tray_activated(self, reason):
        if self.quick_panel is None or reason != QSystemTrayIcon.ActivationReason.Trigger:
            return
        self.quick_panel.refresh()
        self.quick_panel.adjustSize()
        self.quick_panel.show()
        self.quick_panel.raise_()
        self.quick_panel.activateWindow()

    def shutdown(self):
        if self._shutting_down:
            return
        self._shutting_down = True
        self.poller.stop()
        self.click_observer.stop()
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

    def quit(self):
        self.shutdown()
        self.app.quit()


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(_is_windows())
    if not _is_windows() and not QSystemTrayIcon.isSystemTrayAvailable():
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
    app.aboutToQuit.connect(companion.shutdown)
    raise SystemExit(app.exec())
