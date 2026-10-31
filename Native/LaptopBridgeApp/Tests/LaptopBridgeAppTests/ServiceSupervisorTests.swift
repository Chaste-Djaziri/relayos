// Path: Native/LaptopBridgeApp/Tests/LaptopBridgeAppTests/ServiceSupervisorTests.swift
import Foundation
import XCTest
@testable import LaptopBridgeApp

final class ServiceSupervisorTests: XCTestCase {
    @MainActor
    func testCrashRecoveryIsBackedOffAndEventuallyAllowed() {
        let coordinator = ServiceSupervisor()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(coordinator.mayLaunchServer(at: start))
        coordinator.serverDidExit(at: start)
        XCTAssertFalse(coordinator.mayLaunchServer(at: start.addingTimeInterval(1)))
        XCTAssertTrue(coordinator.mayLaunchServer(at: start.addingTimeInterval(2)))
        coordinator.serverDidExit(at: start.addingTimeInterval(2))
        XCTAssertFalse(coordinator.mayLaunchServer(at: start.addingTimeInterval(5)))
        XCTAssertTrue(coordinator.mayLaunchServer(at: start.addingTimeInterval(6)))
        XCTAssertEqual(ServiceSupervisor.delay(for: 10), 60)
    }

    @MainActor
    func testAuthenticatedHealthResetsCrashBackoff() {
        let coordinator = ServiceSupervisor()
        let now = Date(timeIntervalSince1970: 10)
        coordinator.serverDidExit(at: now)
        XCTAssertFalse(coordinator.mayLaunchServer(at: now))
        coordinator.finishProbe(.unauthorized)
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now.addingTimeInterval(5)))
        coordinator.finishProbe(.healthy)
        XCTAssertTrue(coordinator.mayLaunchServer(at: now))
        XCTAssertTrue(coordinator.mayLaunchTunnel(at: now))
    }

    @MainActor
    func testTunnelCrashIsRateLimitedAndManualRestartClearsCooldown() {
        let coordinator = ServiceSupervisor()
        let now = Date(timeIntervalSince1970: 100)
        coordinator.finishProbe(.healthy)
        coordinator.tunnelDidExit(at: now)
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now))
        XCTAssertTrue(coordinator.mayLaunchTunnel(at: now.addingTimeInterval(2)))
        coordinator.tunnelDidExit(at: now.addingTimeInterval(2))
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now.addingTimeInterval(4)))
        coordinator.resetForManualRestart()
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now))
        coordinator.finishProbe(.healthy)
        XCTAssertTrue(coordinator.mayLaunchTunnel(at: now))
    }

    @MainActor
    func testCrashInvalidatesProbeFromDeadServer() {
        let coordinator = ServiceSupervisor()
        let now = Date(timeIntervalSince1970: 50)
        XCTAssertTrue(coordinator.beginProbe(at: now))
        let generation = coordinator.generation
        coordinator.serverDidExit(at: now)
        XCTAssertFalse(coordinator.finishProbe(.healthy, generation: generation))
        XCTAssertEqual(coordinator.health, .unreachable)
        XCTAssertTrue(coordinator.beginProbe(at: now))
        XCTAssertFalse(coordinator.mayLaunchServer(at: now))
    }

    @MainActor
    func testStaleHealthResponseAfterManualRestartIsIgnored() {
        let coordinator = ServiceSupervisor()
        let generation = coordinator.generation
        XCTAssertTrue(coordinator.beginProbe())
        coordinator.resetForManualRestart()
        XCTAssertFalse(coordinator.finishProbe(.healthy, generation: generation))
        XCTAssertEqual(coordinator.health, .unreachable)
        XCTAssertTrue(coordinator.beginProbe())
        XCTAssertTrue(coordinator.finishProbe(.healthy, generation: coordinator.generation))
        XCTAssertEqual(coordinator.health, .healthy)
    }

    @MainActor
    func testHealthProbesDoNotOverlap() {
        let coordinator = ServiceSupervisor()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(coordinator.beginProbe(at: now))
        XCTAssertFalse(coordinator.beginProbe(at: now.addingTimeInterval(10)))
        coordinator.finishProbe(.healthy)
        XCTAssertFalse(coordinator.beginProbe(at: now.addingTimeInterval(1)))
        XCTAssertTrue(coordinator.beginProbe(at: now.addingTimeInterval(5)))
    }
}
