import SwiftUI

struct SettingsToggle: View {
    @Binding var isOn: Bool
    var tintColor: Color = Color(red: 0.18, green: 0.52, blue: 0.98)
    var offColor: Color = Color(red: 0.24, green: 0.24, blue: 0.26)

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? tintColor : offColor)
                    .frame(width: 42, height: 24)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? tintColor.opacity(0.85) : Color(white: 0.32), lineWidth: 0.8)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                    .offset(x: isOn ? 9 : -9)
            }
            .frame(width: 42, height: 24)
            .contentShape(Capsule())
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

struct SleekSwitchToggleStyle: ToggleStyle {
    var tint: Color = Color(red: 0.18, green: 0.52, blue: 0.98)
    var offColor: Color = Color(red: 0.24, green: 0.24, blue: 0.26)

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? tint : offColor)
                        .frame(width: 42, height: 24)
                        .overlay(
                            Capsule()
                                .stroke(configuration.isOn ? tint.opacity(0.85) : Color(white: 0.32), lineWidth: 0.8)
                        )

                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .offset(x: configuration.isOn ? 9 : -9)
                }
                .frame(width: 42, height: 24)
                .contentShape(Capsule())
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isOn)
            }
            .buttonStyle(.plain)
        }
    }
}

extension ToggleStyle where Self == SleekSwitchToggleStyle {
    static var sleekSwitch: SleekSwitchToggleStyle { SleekSwitchToggleStyle() }
    static func sleekSwitch(tint: Color) -> SleekSwitchToggleStyle { SleekSwitchToggleStyle(tint: tint) }
}
