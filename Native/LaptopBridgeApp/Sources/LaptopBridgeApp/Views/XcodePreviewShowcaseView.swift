// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/XcodePreviewShowcaseView.swift
import SwiftUI

// Xcode Debug runs this interactive window without starting the MCP server,
// spawning ngrok, acquiring production's instance lock, or changing approvals.
struct XcodePreviewShowcaseView: View {
    @State private var selection = "Appearance"
    @AppStorage(RelayOSTheme.modeKey) private var appearance = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @Environment(\.colorScheme) private var scheme

    private var palette: ThemeColors { RelayOSTheme.colors(scheme) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("RelayOS").font(.title2.bold())
                Label("Xcode UI Preview", systemImage: "paintbrush.pointed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(["Appearance", "Connections", "System permissions"], id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack {
                            Text(tab)
                            Spacer()
                            if selection == tab { Image(systemName: "checkmark") }
                        }
                        .padding(9)
                        .background(selection == tab ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Label("No MCP services are started", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(palette.sidebarOpaqueBackground)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selection).font(.system(size: 30, weight: .semibold))
                    switch selection {
                    case "Appearance":
                        AppearancePageView()
                    case "Connections":
                        SettingsCard(title: "Connection status — preview data") {
                            SettingsCardRow(title: "Local MCP", subtitle: "Mock service status") {
                                StatusBadge(text: "Healthy", status: .healthy)
                            }
                            SettingsCardRow(title: "Public MCP", subtitle: "Mock endpoint status",
                                            showDivider: false) {
                                StatusBadge(text: "Unavailable", status: .offline)
                            }
                        }
                    default:
                        SettingsCard(title: "Permissions — preview data") {
                            ForEach(Array(SystemPermissionKind.allCases.enumerated()), id: \.element.id) { index, permission in
                                SettingsCardRow(title: permission.title, subtitle: permission.explanation,
                                                showDivider: index < SystemPermissionKind.allCases.count - 1) {
                                    StatusBadge(text: "Check in Settings", status: .neutral)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(palette.windowBackground)
        }
        .preferredColorScheme(RelayOSTheme.scheme(appearance))
        .tint(RelayOSTheme.accent(accent))
    }
}

#if DEBUG
#Preview("Whole UI — Safe Xcode Showcase") {
    XcodePreviewShowcaseView()
        .frame(width: 1050, height: 700)
}
#endif
