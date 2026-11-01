import SwiftUI
import AppKit

struct ToolsPageView: View {
    @ObservedObject var model: BridgeModel
    @State private var pendingRevokeID: String?
    @State private var confirmRevokeAll = false

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
                                    pendingRevokeID = id
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
                            confirmRevokeAll = true
                        }
                    }
                }
            }
        }
        .confirmationDialog("Revoke this folder permission?", isPresented: Binding(
            get: { pendingRevokeID != nil },
            set: { if !$0 { pendingRevokeID = nil } }
        )) {
            Button("Revoke", role: .destructive) {
                if let id = pendingRevokeID { model.revokePermission(id) }
                pendingRevokeID = nil
            }
            Button("Cancel", role: .cancel) { pendingRevokeID = nil }
        } message: {
            Text("This project permission will be unavailable to connected AI clients.")
        }
        .confirmationDialog("Revoke all folder permissions?", isPresented: $confirmRevokeAll) {
            Button("Revoke all permissions", role: .destructive) {
                let ids = model.permissionGrants.compactMap { $0["token"] as? String }
                model.revokePermissions(ids)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing approvals will be removed. New requests will require your authorization.")
        }
    }
}
