import XCTest
@testable import LaptopBridgeApp

final class LaptopBridgeAppTests: XCTestCase {
    func testNativeTargetLoads() {
        XCTAssertTrue(true)
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
