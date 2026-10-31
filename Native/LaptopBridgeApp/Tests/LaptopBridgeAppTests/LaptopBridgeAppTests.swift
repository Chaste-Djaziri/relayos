import XCTest
@testable import LaptopBridgeApp

final class LaptopBridgeAppTests: XCTestCase {
    func testNativeTargetLoads() {
        XCTAssertTrue(true)
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
