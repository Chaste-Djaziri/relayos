import SwiftUI
import AppKit

struct AppearancePageView: View {
    @AppStorage(RelayOSTheme.modeKey) private var mode = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var fontSize = 14.0
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false
    @AppStorage(RelayOSTheme.sidebarTransparencyKey) private var sidebarTransparency = true

    @Environment(\.colorScheme) private var colorScheme

    private var theme: ThemeColors {
        RelayOSTheme.colors(colorScheme)
    }

    private var scale: CGFloat {
        RelayOSTheme.scale(fontSize)
    }

    private var accentColor: Color {
        RelayOSTheme.accent(accent)
    }

    private let accentColors = [
        ("blue", "Blue", Color(red: 0.12, green: 0.53, blue: 0.98)),
        ("green", "Green", Color(red: 0.18, green: 0.76, blue: 0.40)),
        ("purple", "Purple", Color(red: 0.65, green: 0.38, blue: 0.96)),
        ("orange", "Orange", Color(red: 1.00, green: 0.55, blue: 0.16)),
        ("pink", "Pink", Color(red: 0.96, green: 0.32, blue: 0.58))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Interface Theme") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        themePreviewCard("system", title: "System", icon: "circle.lefthalf.filled")
                        themePreviewCard("light", title: "Light", icon: "sun.max")
                        themePreviewCard("dark", title: "Dark", icon: "moon.stars")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }

            SettingsCard(title: "Color & Typography") {
                SettingsCardRow(
                    title: "Accent color",
                    subtitle: "Accent tone used for active highlights, buttons, and switches"
                ) {
                    HStack(spacing: 8) {
                        ForEach(accentColors, id: \.0) { key, name, color in
                            Button {
                                accent = key
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                        )

                                    if accent == key {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(2)
                                .overlay(
                                    Circle()
                                        .stroke(accent == key ? color : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                }

                SettingsCardRow(
                    title: "Interface text size",
                    subtitle: "Scale font sizing across RelayOS windows",
                    showDivider: false
                ) {
                    HStack(spacing: 12) {
                        Text("A")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)

                        Slider(value: $fontSize, in: 12...18, step: 1)
                            .frame(width: 130)

                        Text("A")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.textSecondary)

                        Text("\(Int(fontSize)) pt")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            SettingsCollapsibleCard(
                title: "Advanced",
                subtitle: "Accessibility preferences and window vibrancy options",
                initiallyExpanded: true
            ) {
                SettingsCardRow(
                    title: "Translucent sidebar",
                    subtitle: "Enable native macOS vibrancy blur on the navigation sidebar."
                ) {
                    SettingsToggle(isOn: $sidebarTransparency)
                }

                SettingsCardRow(
                    title: "Reduce motion",
                    subtitle: "Minimizes and disables UI animations across the interface.",
                    showDivider: false
                ) {
                    SettingsToggle(isOn: $reduceMotion)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themePreviewCard(_ value: String, title: String, icon: String) -> some View {
        Button {
            mode = value
        } label: {
            VStack(spacing: 9) {
                ZStack {
                    if value == "system" {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color(white: 0.94))
                            Rectangle()
                                .fill(Color(white: 0.14))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.75).opacity(0.7))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule().fill(accentColor).frame(width: 32, height: 4)
                                Capsule().fill(Color.gray.opacity(0.3)).frame(height: 4)
                            }
                            .padding(8)
                        }
                    } else if value == "light" {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(white: 0.95))

                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.82))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule().fill(Color.black.opacity(0.2)).frame(height: 4)
                                Capsule().fill(accentColor).frame(width: 32, height: 4)
                                Capsule().fill(Color.black.opacity(0.12)).frame(height: 4)
                            }
                            .padding(8)
                        }
                        .padding(4)
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(white: 0.13))

                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.22))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule().fill(Color.gray.opacity(0.4)).frame(height: 4)
                                Capsule().fill(accentColor).frame(width: 32, height: 4)
                                Capsule().fill(Color.gray.opacity(0.2)).frame(height: 4)
                            }
                            .padding(8)
                        }
                        .padding(4)
                    }
                }
                .frame(width: 104, height: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            mode == value ? accentColor : (colorScheme == .dark ? Color(white: 0.25) : Color(white: 0.80)),
                            lineWidth: mode == value ? 2 : 1
                        )
                )

                Label(title, systemImage: icon)
                    .font(.system(size: 12 * scale, weight: mode == value ? .semibold : .regular))
                    .foregroundStyle(mode == value ? theme.textPrimary : theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

typealias RelayOSAppearanceView = AppearancePageView
