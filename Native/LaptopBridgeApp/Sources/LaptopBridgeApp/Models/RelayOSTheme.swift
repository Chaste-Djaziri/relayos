import SwiftUI
import AppKit

enum RelayOSTheme {
    static let modeKey = "relayos.appearance"
    static let accentKey = "relayos.accent"
    static let fontSizeKey = "relayos.uiFontSize"
    static let reduceMotionKey = "relayos.reduceMotion"
    static let sidebarTransparencyKey = "relayos.sidebarTransparency"

    static func scheme(_ mode: String) -> ColorScheme? {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static func accent(_ name: String) -> Color {
        switch name {
        case "blue":
            return Color(red: 0.12, green: 0.53, blue: 0.98)
        case "green":
            return Color(red: 0.18, green: 0.76, blue: 0.40)
        case "purple":
            return Color(red: 0.65, green: 0.38, blue: 0.96)
        case "orange":
            return Color(red: 1.00, green: 0.55, blue: 0.16)
        case "pink":
            return Color(red: 0.96, green: 0.32, blue: 0.58)
        default:
            return Color(red: 0.12, green: 0.53, blue: 0.98)
        }
    }

    static func colors(_ scheme: ColorScheme) -> ThemeColors {
        ThemeColors(isDark: scheme == .dark)
    }

    static func scale(_ userFontSize: Double) -> CGFloat {
        let size = userFontSize > 0 ? userFontSize : 14.0
        return CGFloat(size / 14.0)
    }
}

struct ThemeColors {
    let isDark: Bool

    var windowBackground: Color {
        isDark ? Color(red: 0.095, green: 0.095, blue: 0.095) : Color(red: 0.955, green: 0.955, blue: 0.965)
    }

    var sidebarOpaqueBackground: Color {
        isDark ? Color(red: 0.095, green: 0.095, blue: 0.095) : Color(red: 0.925, green: 0.925, blue: 0.935)
    }

    var sidebarSearchBackground: Color {
        isDark ? Color(white: 0.16) : Color(white: 0.88)
    }

    var cardBackground: Color {
        isDark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color.white
    }

    var cardBorder: Color {
        isDark ? Color(white: 0.19) : Color(white: 0.86)
    }

    var cardDivider: Color {
        isDark ? Color(white: 0.18) : Color(white: 0.90)
    }

    var textPrimary: Color {
        isDark ? .white : Color(red: 0.10, green: 0.10, blue: 0.12)
    }

    var textSecondary: Color {
        isDark ? Color(white: 0.55) : Color(white: 0.42)
    }

    var textMuted: Color {
        isDark ? Color(white: 0.40) : Color(white: 0.55)
    }

    var codeBackground: Color {
        isDark ? Color(white: 0.12) : Color(white: 0.94)
    }

    var codeText: Color {
        isDark ? Color(red: 0.45, green: 0.80, blue: 1.0) : Color(red: 0.08, green: 0.42, blue: 0.85)
    }
}
