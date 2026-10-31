// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSApp.swift
import SwiftUI
import AppKit

final class RelayOSApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
struct LaptopBridgeApp: App {
    @StateObject private var model = BridgeModel.shared
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
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        MenuBarExtra {
            QuickPanel(model: model)
                .frame(width: 360)
        } label: {
            Image(systemName: "cursorarrow")
                .frame(width: 18, height: 18)
                .accessibilityLabel("RelayOS")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
