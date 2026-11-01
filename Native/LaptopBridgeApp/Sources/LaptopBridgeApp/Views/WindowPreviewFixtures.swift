// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Views/WindowPreviewFixtures.swift
import SwiftUI

// Inert previews: never initialize the live BridgeModel or trigger MCP commands.
// These render the visual design without accessing the user's machine.
#if DEBUG
#Preview("Appearance - Dark") {
    ScrollView {
        AppearancePageView()
            .padding(28)
            .frame(maxWidth: 780)
    }
    .frame(width: 950, height: 730)
    .preferredColorScheme(.dark)
}

#Preview("Appearance - Light") {
    ScrollView {
        AppearancePageView()
            .padding(28)
            .frame(maxWidth: 780)
    }
    .frame(width: 950, height: 730)
    .preferredColorScheme(.light)
}

#Preview("Permission guidance cards") {
    VStack(alignment: .leading, spacing: 20) {
        Text("System permissions").font(.largeTitle)
        SettingsCard(title: "Permissions") {
            ForEach(SystemPermissionKind.allCases) { kind in
                SettingsCardRow(title: kind.title, subtitle: kind.explanation) {
                    StatusBadge(text: "Check in Settings", status: .neutral)
                }
            }
        }
    }
    .padding(28)
    .frame(width: 940, height: 700)
    .preferredColorScheme(.dark)
}

#Preview("Settings controls - Light") {
    VStack(alignment: .leading, spacing: 20) {
        SettingsCard(title: "Connections") {
            SettingsCardRow(title: "Local MCP", subtitle: "A verified local service") {
                StatusBadge(text: "Healthy", status: .healthy)
            }
            SettingsCardRow(title: "Public MCP", subtitle: "An unreachable endpoint") {
                StatusBadge(text: "Unavailable", status: .offline)
            }
        }
        SettingsCard(title: "Appearance") {
            SettingsCardRow(title: "Theme", subtitle: "System appearance") {
                Text("Light").foregroundStyle(.secondary)
            }
        }
    }
    .padding(28)
    .frame(width: 940, height: 500)
    .preferredColorScheme(.light)
}
#endif
