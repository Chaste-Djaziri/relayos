import SwiftUI
import AppKit

struct ToolsPageView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Available tools") {
                SettingsCardRow(
                    title: "Project tools",
                    subtitle: "Enable workspace filesystem and development tools for connected AI clients"
                ) {
                    SettingsToggle(isOn: $model.projectTools)
                }

                SettingsCardRow(
                    title: "Persist configuration",
                    subtitle: "Save tool preferences to disk",
                    showDivider: false
                ) {
                    SettingsButton(title: "Save tool settings", style: .secondary) {
                        model.saveCapabilities()
                    }
                }
            }

            SettingsCard(title: "Persistent folder grants") {
                if model.permissionGrants.isEmpty {
                    SettingsCardRow(
                        title: "No persistent permissions yet",
                        subtitle: "Permissions granted with 'Always' appear here for inspection and revocation.",
                        showDivider: false
                    ) {
                        Text("None")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.5))
                    }
                } else {
                    ForEach(Array(model.permissionGrants.enumerated()), id: \.offset) { _, grant in
                        SettingsCardRow(
                            title: (grant["grant_type"] as? String ?? "permission").capitalized,
                            subtitle: grant["scope"] as? String ?? ""
                        ) {
                            SettingsButton(title: "Revoke", style: .destructive) {
                                if let id = grant["token"] as? String {
                                    model.revokePermission(id)
                                }
                            }
                        }
                    }

                    SettingsCardRow(
                        title: "Revoke all",
                        subtitle: "Revoke every persistent folder permission immediately",
                        showDivider: false
                    ) {
                        SettingsButton(title: "Revoke all permissions", style: .destructive) {
                            for grant in model.permissionGrants {
                                if let id = grant["token"] as? String {
                                    model.revokePermission(id)
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "macOS system permissions") {
                SettingsCardRow(
                    title: "Screen recording",
                    subtitle: "Managed by macOS Privacy & Security. Screen capture tools require user authorization in System Settings.",
                    showDivider: false
                ) {
                    SettingsButton(title: "Open Privacy & Security", icon: "lock.shield", style: .secondary) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
