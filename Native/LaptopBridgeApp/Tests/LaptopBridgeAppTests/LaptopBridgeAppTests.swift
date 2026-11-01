import XCTest
@testable import LaptopBridgeApp

final class LaptopBridgeAppTests: XCTestCase {
    func testNativeTargetLoads() {
        XCTAssertTrue(true)
    }

    func testXcodeRunIsNotADataPreview() {
        // SwiftUI Canvas opts into samples explicitly; Xcode Run doesn't.
        XCTAssertFalse(RelayOSApplicationDelegate.usesSampleModel(
            environment: ["RELAYOS_NATIVE_MCP_EXPERIMENT": "1"]))
        XCTAssertFalse(RelayOSApplicationDelegate.usesSampleModel(environment: [:]))
        XCTAssertTrue(RelayOSApplicationDelegate.usesSampleModel(
            environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        XCTAssertTrue(RelayOSApplicationDelegate.usesSampleModel(
            environment: ["RELAYOS_XCODE_UI_PREVIEW": "1"]))
    }

    @MainActor
    func testClosingSettingsDoesNotTerminatePersistentAgent() {
        let delegate = RelayOSApplicationDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testPermissionGuideOnlyOffersDragForAppLists() {
        XCTAssertTrue(SystemPermissionKind.screenRecording.supportsAppDrag)
        XCTAssertTrue(SystemPermissionKind.fullDiskAccess.supportsAppDrag)
        XCTAssertTrue(SystemPermissionKind.accessibility.supportsAppDrag)
        XCTAssertFalse(SystemPermissionKind.notifications.supportsAppDrag)
        XCTAssertFalse(SystemPermissionKind.automation.supportsAppDrag)
        XCTAssertEqual(SystemPermissionKind.fullDiskAccess.settingsAnchor, "Privacy_AllFiles")
        XCTAssertEqual(PermissionObservation.manual.label, "Check in Settings")
    }

    func testDevelopmentRootIsDiscoveredFromNestedBuildDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RelayOS-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("src/laptop_bridge"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("pyproject.toml"))
        try Data().write(to: root.appendingPathComponent("src/laptop_bridge/__init__.py"))
        let nested = root.appendingPathComponent("Native/LaptopBridgeApp/.build/debug")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(DevelopmentRuntimeLocator.projectRoot(startingAt: [nested])?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertNil(DevelopmentRuntimeLocator.projectRoot(startingAt: [fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)]))
    }

    @MainActor
    func testOldTerminationCannotClearReplacement() {
        let slot = ManagedProcessSlot()
        let earlier = Process()
        let replacement = Process()

        slot.assign(earlier)
        slot.assign(replacement)

        XCTAssertFalse(slot.clearIfMatches(earlier))
        XCTAssertTrue(slot.process === replacement)
        XCTAssertTrue(slot.clearIfMatches(replacement))
        XCTAssertNil(slot.process)
    }

    @MainActor
    func testRealChildCrashCannotClearReplacementSlot() throws {
        let slot = ManagedProcessSlot()
        let original = Process()
        original.executableURL = URL(fileURLWithPath: "/bin/sleep")
        original.arguments = ["30"]
        let replacement = Process()
        replacement.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacement.arguments = ["30"]

        try original.run()
        defer { if original.isRunning { original.terminate() }; original.waitUntilExit() }
        slot.assign(original)
        try replacement.run()
        defer { if replacement.isRunning { replacement.terminate() }; replacement.waitUntilExit() }
        slot.assign(replacement)

        original.terminate()
        original.waitUntilExit()
        XCTAssertFalse(slot.clearIfMatches(original))
        XCTAssertTrue(slot.process === replacement)
        replacement.terminate()
        replacement.waitUntilExit()
        XCTAssertTrue(slot.clearIfMatches(replacement))
        XCTAssertNil(slot.process)
    }

    @MainActor
    func testServicesDoNotStartBeforeInstanceLock() {
        let model = BridgeModel()
        model.startServices()
        model.startTunnelIfConfigured()

        XCTAssertFalse(SingleInstanceCoordinator.shared.ownsLock)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.tunnelRunning)
    }
}
