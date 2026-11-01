import SwiftUI
import AppKit

struct CustomTrafficLights: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSApp.keyWindow?.close() ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.close()
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.38, blue: 0.35))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.88, green: 0.20, blue: 0.18), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.05, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close settings window")

            Button {
                NSApp.keyWindow?.miniaturize(nil) ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.miniaturize(nil)
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.22))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.87, green: 0.60, blue: 0.10), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.30, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize window")

            Button {
                NSApp.keyWindow?.zoom(nil) ?? NSApp.windows.first(where: { $0.title == "RelayOS" })?.zoom(nil)
            } label: {
                Circle()
                    .fill(Color(red: 0.16, green: 0.78, blue: 0.30))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(red: 0.12, green: 0.65, blue: 0.20), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color(red: 0.05, green: 0.35, blue: 0.05))
                            .opacity(isHovering ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom window")
        }
        .onHover { isHovering = $0 }
    }
}

typealias CustomTrafficLightsAndNav = CustomTrafficLights
