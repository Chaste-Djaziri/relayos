import SwiftUI

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var tintColor: Color? = nil
    var offColor: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.reduceMotionKey) private var reduceMotion = false

    private var activeTint: Color {
        tintColor ?? RelayOSTheme.accent(accent)
    }

    private var inactiveColor: Color {
        offColor ?? (colorScheme == .dark
            ? Color(red: 0.24, green: 0.24, blue: 0.26)
            : Color(red: 0.86, green: 0.86, blue: 0.88))
    }

    private var inactiveBorder: Color {
        colorScheme == .dark ? Color(white: 0.32) : Color(white: 0.72)
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? activeTint : inactiveColor)
                    .frame(width: 42, height: 24)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? activeTint.opacity(0.85) : inactiveBorder, lineWidth: 0.8)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.15), radius: 2, x: 0, y: 1)
                    .offset(x: isOn ? 9 : -9)
            }
            .frame(width: 42, height: 24)
            .contentShape(Capsule())
            .animation(
                (reduceMotion || systemReduceMotion) ? nil : .spring(response: 0.22, dampingFraction: 0.82),
                value: isOn
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Setting")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

struct SleekSwitchToggleStyle: ToggleStyle {
    var tint: Color? = nil
    var offColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            SettingsToggle(
                isOn: configuration.$isOn,
                tintColor: tint,
                offColor: offColor
            )
        }
    }
}

extension ToggleStyle where Self == SleekSwitchToggleStyle {
    static var sleekSwitch: SleekSwitchToggleStyle { SleekSwitchToggleStyle() }
    static func sleekSwitch(tint: Color) -> SleekSwitchToggleStyle { SleekSwitchToggleStyle(tint: tint) }
}
