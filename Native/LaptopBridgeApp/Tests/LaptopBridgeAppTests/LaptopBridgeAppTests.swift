import XCTest
@testable import LaptopBridgeApp

final class LaptopBridgeAppTests: XCTestCase {
    func testNativeTargetLoads() {
        XCTAssertTrue(true)
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
    func testServicesDoNotStartBeforeInstanceLock() {
        let model = BridgeModel()
        model.startServices()
        model.startTunnelIfConfigured()

        XCTAssertFalse(SingleInstanceCoordinator.shared.ownsLock)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.tunnelRunning)
    }
}
