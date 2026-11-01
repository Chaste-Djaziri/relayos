// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/RelayOSApp.swift
import SwiftUI
import AppKit

final class RelayOSApplicationDelegate: NSObject, NSApplicationDelegate {
    // This optional developer-mode service lives INSIDE RelayOS.app.
    // It never replaces the existing production listener on :8765.
    private var nativeExperiment: NativeMCPListener?
    // Only Canvas/explicit previews use artificial data. Pressing Run in Xcode
    // opens the real settings application with live configuration and state.
    static func usesSampleModel(environment: [String: String]) -> Bool {
        environment["RELAYOS_XCODE_UI_PREVIEW"] == "1"
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    static var isXcodeUIPreview: Bool {
        usesSampleModel(environment: ProcessInfo.processInfo.environment)
    }
    static var isXcodeDevelopment: Bool {
        Bundle.main.bundleIdentifier == "pro.micorp.relayos.dev"
    }
    static var isSwiftOnlyDevelopment: Bool {
        isXcodeDevelopment &&
            ProcessInfo.processInfo.environment["RELAYOS_SWIFT_ONLY"] == "1"
    }
    // The settings window is not the agent's lifetime. Explicit Quit terminates
    // RelayOS; simply closing Settings leaves its approved MCP services alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI Canvas must never bootstrap a token, listener, or helper.
        guard !Self.isXcodeUIPreview else { return }
        if Self.isSwiftOnlyDevelopment {
            do {
                let auth = try NativeMCPDevelopmentStore().bootstrap()
                let listener = NativeMCPListener(port: 18765, authorization: auth, approvalStore: NativeMCPApprovalStore(databaseURL: NativeMCPDevelopmentStore().databaseURL),
                                                 oauth: NativeMCPOAuth(store: NativeMCPDevelopmentStore()))
                try listener.start()
                nativeExperiment = listener
                BridgeModel.shared.nativeListenerStarted()
            } catch {
                BridgeModel.shared.serviceNotice = "Swift-only listener failed: \(error.localizedDescription)"
                BridgeModel.shared.mcpHealth = .unreachable
            }
        }
        if Self.isXcodeDevelopment {
            // Swift-only runs in the app itself; observation mode reads the
            // installed backend but does not own or stop its processes.
            if !Self.isSwiftOnlyDevelopment {
                BridgeModel.shared.startDevelopmentObservation()
                BridgeModel.shared.startCommandJobMonitoring()
            }
            Task { @MainActor in
                NotchPanelCoordinator.shared.ensurePresentedOnLaunch(model: BridgeModel.shared)
            }
            RelayOSCursorCompanion.shared.start()
            return
        }
        guard SingleInstanceCoordinator.shared.claimOrReplaceExistingInstance() else {
            NSApplication.shared.terminate(nil)
            return
        }
        BridgeModel.shared.startServices()
        BridgeModel.shared.startCommandJobMonitoring()
        RelayOSCursorCompanion.shared.start()
        Task { @MainActor in
            NotchPanelCoordinator.shared.ensurePresentedOnLaunch(model: BridgeModel.shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RelayOSCursorCompanion.shared.stop()
        nativeExperiment?.stop()
        nativeExperiment = nil
        BridgeModel.shared.stopNativeInboxPolling()
        BridgeModel.shared.stopCommandJobMonitoring()
        guard !Self.isXcodeUIPreview else { return }
        if Self.isXcodeDevelopment {
            BridgeModel.shared.stopDevelopmentObservation()
            return
        }
        BridgeModel.shared.shutdownServices()
        SingleInstanceCoordinator.shared.release()
    }
}

@main
struct RelayOSApp: App {
    @StateObject private var model: BridgeModel
    @AppStorage(RelayOSTheme.modeKey) private var appearance = "system"
    @AppStorage(RelayOSTheme.accentKey) private var accent = "blue"
    @AppStorage(RelayOSTheme.fontSizeKey) private var uiFontSize = 14.0
    @NSApplicationDelegateAdaptor(RelayOSApplicationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        let initialModel = RelayOSApplicationDelegate.isXcodeUIPreview
            ? BridgeModel.preview() : BridgeModel.shared
        #else
        let initialModel = BridgeModel.shared
        #endif
        _model = StateObject(wrappedValue: initialModel)
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
                    NotchPanelCoordinator.shared.registerOpenMainWindow {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    NotchPanelCoordinator.shared.ensurePresentedOnLaunch(model: model)
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first(where: { $0.title == "RelayOS" })?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("RelayOS Controls") {
                Button("Open Control Center") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("Toggle Notch Panel") {
                    NotchPanelCoordinator.shared.toggle(model: model) {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()
                Button("Review Approvals") {
                    model.showApprovalCenter()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        MenuBarExtra {
            QuickPanel(model: model)
                .allowsHitTesting(!model.isPreview)
                .preferredColorScheme(RelayOSTheme.scheme(appearance))
                .tint(RelayOSTheme.accent(accent))
                .frame(width: 384)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.stack.3d.up.fill")
                    .frame(width: 18, height: 18)
                if (model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count) > 0 {
                    Text("\(model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count)")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .accessibilityLabel("RelayOS — \(model.isSwiftOnly ? model.nativePendingCount : model.approvalInbox.count) pending approvals")
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
