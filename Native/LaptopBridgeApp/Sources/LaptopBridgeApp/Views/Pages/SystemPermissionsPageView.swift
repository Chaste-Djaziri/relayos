import SwiftUI
import AppKit
import UserNotifications
import ApplicationServices
import CoreGraphics

struct SystemPermissionsPageView: View {
    @ObservedObject var model: BridgeModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var hasScreenRecording = false
    @State private var hasFullDiskAccess = false
    @State private var hasAccessibility = false
    @State private var hasNotifications = false

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Manage permissions required by RelayOS and paired AI clients to inspect projects, automate workflows, and display alerts.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                SettingsButton(title: "Check permissions", icon: "arrow.clockwise", style: .secondary) {
                    refreshPermissionStatuses()
                }
            }
            .padding(.bottom, 2)

            SettingsCard(title: "Core System Permissions") {
                SettingsCardRow(
                    title: "Screen Recording",
                    subtitle: "Allows RelayOS to capture display snapshots and guide cursor overlays when an agent inspects your screen."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: hasScreenRecording ? "Granted" : "Not granted",
                            status: hasScreenRecording ? .healthy : .warning
                        )
                        SettingsButton(
                            title: hasScreenRecording ? "Settings" : "Grant access",
                            icon: "video.fill",
                            style: hasScreenRecording ? .secondary : .primary
                        ) {
                            if !hasScreenRecording {
                                _ = CGRequestScreenCaptureAccess()
                            }
                            openPrivacySetting("Privacy_ScreenCapture")
                        }
                    }
                }

                SettingsCardRow(
                    title: "Full Disk Access",
                    subtitle: "Permits RelayOS and tools to access, read, and write project files across all local folders without recurring system dialogs."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: hasFullDiskAccess ? "Granted" : "Not granted",
                            status: hasFullDiskAccess ? .healthy : .warning
                        )
                        SettingsButton(
                            title: hasFullDiskAccess ? "Settings" : "Configure",
                            icon: "internaldrive",
                            style: hasFullDiskAccess ? .secondary : .primary
                        ) {
                            openPrivacySetting("Privacy_AllFiles")
                        }
                    }
                }

                SettingsCardRow(
                    title: "Device Control & Accessibility",
                    subtitle: "Allows assistive cursor movements, synthetic clicks, and window positioning for automated agent assistance."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: hasAccessibility ? "Granted" : "Not granted",
                            status: hasAccessibility ? .healthy : .warning
                        )
                        SettingsButton(
                            title: hasAccessibility ? "Settings" : "Grant access",
                            icon: "hand.raised.fill",
                            style: hasAccessibility ? .secondary : .primary
                        ) {
                            if !hasAccessibility {
                                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                                _ = AXIsProcessTrustedWithOptions(options)
                            }
                            openPrivacySetting("Privacy_Accessibility")
                        }
                    }
                }

                SettingsCardRow(
                    title: "Push Notifications",
                    subtitle: "Displays alerts and sound notifications when a new command or connection approval is pending.",
                    showDivider: false
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: hasNotifications ? "Enabled" : "Not enabled",
                            status: hasNotifications ? .healthy : .neutral
                        )
                        SettingsButton(
                            title: hasNotifications ? "Settings" : "Enable",
                            icon: "bell.badge.fill",
                            style: hasNotifications ? .secondary : .primary
                        ) {
                            if !hasNotifications {
                                ApprovalArrivalNotification.requestPermission()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    refreshPermissionStatuses()
                                }
                            }
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "Automation & Extended Access") {
                SettingsCardRow(
                    title: "Automation (Apple Events)",
                    subtitle: "Enables RelayOS to control scriptable macOS applications (Terminal, VS Code, Xcode, Finder) during paired sessions."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(text: "Configured per-app", status: .neutral)
                        SettingsButton(title: "Open Settings", icon: "applescript", style: .secondary) {
                            openPrivacySetting("Privacy_Automation")
                        }
                    }
                }

                SettingsCardRow(
                    title: "App Management",
                    subtitle: "Allows RelayOS to manage, install, or update local developer utilities, CLI tools, and development packages."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(text: "macOS managed", status: .neutral)
                        SettingsButton(title: "Open Settings", icon: "app.badge.checkmark", style: .secondary) {
                            openPrivacySetting("Privacy_AppBundles")
                        }
                    }
                }

                SettingsCardRow(
                    title: "Data & Files Access",
                    subtitle: "Permits access to standard system directories (Desktop, Documents, Downloads, Removable Volumes).",
                    showDivider: false
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(text: "Ready", status: .neutral)
                        SettingsButton(title: "Open Settings", icon: "folder.badge.gearshape", style: .secondary) {
                            openPrivacySetting("Privacy_FilesAndFolders")
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshPermissionStatuses()
        }
    }

    private func refreshPermissionStatuses() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()

        let safariDir = NSHomeDirectory() + "/Library/Safari"
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: safariDir)

        hasAccessibility = AXIsProcessTrusted()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.hasNotifications = (settings.authorizationStatus == .authorized)
            }
        }
    }

    private func openPrivacySetting(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

