// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSApp.swift
import SwiftUI
import AppKit

final class RelayOSApplicationDelegate: NSObject, NSApplicationDelegate {
    // Xcode's dedicated Debug bundle identifier is safe to launch beside installed RelayOS.
    // A UI-only development run never acquires the production process lease.
    static var isXcodeUIPreview: Bool {
        ProcessInfo.processInfo.environment["RELAYOS_XCODE_UI_PREVIEW"] == "1"
            || Bundle.main.bundleIdentifier == "pro.micorp.relayos.dev"
    }
    // The settings window is not the agent's lifetime. Explicit Quit terminates
    // RelayOS; simply closing Settings leaves its approved MCP services alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isXcodeUIPreview else { return }
        guard SingleInstanceCoordinator.shared.claimOrReplaceExistingInstance() else {
            NSApplication.shared.terminate(nil)
            return
        }
        BridgeModel.shared.startServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isXcodeUIPreview else { return }
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
            Group {
                if RelayOSApplicationDelegate.isXcodeUIPreview {
                    XcodePreviewShowcaseView()
                } else {
                    DesktopWindowView(model: model)
                }
            }
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
