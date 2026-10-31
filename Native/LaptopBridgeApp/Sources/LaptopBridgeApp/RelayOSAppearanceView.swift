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
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Visual style").font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                Text("Mode").font(.subheadline.weight(.medium))
                HStack(spacing: 14) {
                    preview("system", title: "System", icon: "circle.lefthalf.filled")
                    preview("light", title: "Light", icon: "sun.max")
                    preview("dark", title: "Dark", icon: "moon.stars")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Accent color")
                    Spacer()
                    Picker("Accent color", selection: $accent) {
                        ForEach(["blue", "green", "purple", "orange", "pink"], id: \.self) { color in
                            Text(color.capitalized).tag(color)
                        }
                    }.labelsHidden().frame(width: 140)
                }
                Divider()
                HStack {
                    Text("Interface text size")
                    Spacer()
                    Slider(value: $fontSize, in: 12...18, step: 1).frame(width: 170)
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                Text("Changes apply immediately and are saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Reduce motion", isOn: $reduceMotion)
                    Toggle("Use translucent sidebar", isOn: $sidebarTransparency)
                    Text("Reduce motion minimizes optional UI animation. macOS accessibility preferences still take priority.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.padding(18)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(mode == value ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: mode == value ? 2 : 1))
                Label(title, systemImage: icon).font(.caption)
            }
        }.buttonStyle(.plain).frame(maxWidth: 115)
            .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}
