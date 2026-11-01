// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSAppearanceView.swift
import SwiftUI
import AppKit

enum RelayOSTheme {
    static let modeKey = "relayos.appearance"
    static let accentKey = "relayos.accent"
    static let fontSizeKey = "relayos.uiFontSize"
    static let reduceMotionKey = "relayos.reduceMotion"
    static let sidebarTransparencyKey = "relayos.sidebarTransparency"
    static func scheme(_ mode: String) -> ColorScheme? {
        switch mode { case "light": return .light; case "dark": return .dark; default: return nil }
    }
    static func accent(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "green": return .green
        case "purple": return .purple
        case "orange": return .orange
        case "pink": return .pink
        default: return .primary
        }
    }
}

struct RelayOSAppearanceView: View {
    @AppStorage(RelayOSTheme.modeKey) private var mode = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var fontSize = 14.0
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false
    @AppStorage(RelayOSTheme.sidebarTransparencyKey) private var sidebarTransparency = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Interface Theme") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        preview("system", title: "System", icon: "circle.lefthalf.filled")
                        preview("light", title: "Light", icon: "sun.max")
                        preview("dark", title: "Dark", icon: "moon.stars")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }

            SettingsCard(title: "Color & Typography") {
                SettingsCardRow(
                    title: "Accent color",
                    subtitle: "Accent tone used for active highlights and controls"
                ) {
                    Picker("Accent color", selection: $accent) {
                        ForEach(["blue", "green", "purple", "orange", "pink"], id: \.self) { color in
                            Text(color.capitalized).tag(color)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingsCardRow(
                    title: "Interface text size",
                    subtitle: "Scale font sizing across RelayOS windows",
                    showDivider: false
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $fontSize, in: 12...18, step: 1)
                            .frame(width: 140)
                        Text("\(Int(fontSize)) pt")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(white: 0.8))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            SettingsCollapsibleCard(
                title: "Advanced",
                subtitle: "Accessibility preferences and window vibrancy options",
                initiallyExpanded: false
            ) {
                SettingsCardRow(
                    title: "Reduce motion",
                    subtitle: "Minimizes optional UI animations. macOS accessibility preferences take priority."
                ) {
                    SettingsToggle(isOn: $reduceMotion)
                }

                SettingsCardRow(
                    title: "Translucent sidebar",
                    subtitle: "Enable macOS vibrancy on the navigation sidebar.",
                    showDivider: false
                ) {
                    SettingsToggle(isOn: $sidebarTransparency)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preview(_ value: String, title: String, icon: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(value == "dark" ? Color(white: 0.13) : Color(white: 0.95))
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(value == "dark" ? Color(white: 0.22) : Color(white: 0.82))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(value == "dark" ? .gray : .black.opacity(0.25)).frame(height: 4)
                            Capsule().fill(Color.accentColor).frame(width: 38, height: 5)
                            Capsule().fill(value == "dark" ? .gray : .black.opacity(0.15)).frame(height: 4)
                        }.padding(8)
                    }.padding(8)
                }
                .frame(height: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(mode == value ? Color.blue : Color(white: 0.25), lineWidth: mode == value ? 2 : 1)
                )
                Label(title, systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(mode == value ? .white : Color(white: 0.7))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 115)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}
