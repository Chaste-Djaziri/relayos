// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSApp.swift
import SwiftUI
import AppKit

final class RelayOSApplicationDelegate: NSObject, NSApplicationDelegate {
    // Closing the only RelayOS window is an explicit stop request. This lets
    // applicationWillTerminate shut down the owned MCP and ngrok children so
    // the next launch always starts a fresh, single service set.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceCoordinator.shared.claimOrReplaceExistingInstance() else {
            NSApplication.shared.terminate(nil)
            return
        }
        BridgeModel.shared.startServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeModel.shared.shutdownServices()
        SingleInstanceCoordinator.shared.release()
    }
}

@main
struct RelayOSApp: App {
    @StateObject private var model = BridgeModel.shared
    @AppStorage(RelayOSTheme.modeKey) private var appearance = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var uiFontSize = 14.0
    @NSApplicationDelegateAdaptor(RelayOSApplicationDelegate.self) private var appDelegate

    init() {
        // Use a native macOS glyph for both surfaces. Status-item images are
        // rendered as template masks, so bitmap logos can disappear against
        // the menu bar; the system mouse glyph remains visible in every theme.
        if let image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "RelayOS") {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        Window("RelayOS", id: "main") {
            DesktopWindowView(model: model)
                .preferredColorScheme(RelayOSTheme.scheme(appearance))
                .tint(RelayOSTheme.accent(accent))
                .environment(\.font, .system(size: uiFontSize))
                .frame(minWidth: 920, minHeight: 620)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra {
            QuickPanel(model: model)
                .preferredColorScheme(RelayOSTheme.scheme(appearance))
                .tint(RelayOSTheme.accent(accent))
                .frame(width: 360)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cursorarrow")
                    .frame(width: 18, height: 18)
                if !model.approvalInbox.isEmpty {
                    Text("\(model.approvalInbox.count)")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .accessibilityLabel("RelayOS — \(model.approvalInbox.count) pending approvals")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(RelayOSTheme.scheme(appearance))
                .tint(RelayOSTheme.accent(accent))
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
