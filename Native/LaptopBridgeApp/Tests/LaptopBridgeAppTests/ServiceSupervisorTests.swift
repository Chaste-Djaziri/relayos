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
    func testOwnedServerNeedsFiveUnreachableProbesBeforeRecycle() {
        let coordinator = ServiceSupervisor()
        for _ in 0..<4 {
            coordinator.finishProbe(.unreachable)
            XCTAssertFalse(coordinator.shouldRecycleOwnedServer)
        }
        coordinator.finishProbe(.unreachable)
        XCTAssertTrue(coordinator.shouldRecycleOwnedServer)
        coordinator.serverDidExit()
        XCTAssertFalse(coordinator.shouldRecycleOwnedServer)
    }

    @MainActor
    func testUnauthorizedAndUnexpectedListenerNeverTriggerRecycle() {
        let coordinator = ServiceSupervisor()
        for _ in 0..<10 {
            coordinator.finishProbe(.unauthorized)
            coordinator.finishProbe(.unexpectedService)
        }
        XCTAssertFalse(coordinator.shouldRecycleOwnedServer)
    }

    @MainActor
    func testTunnelHealthRecoveryAndStaleResults() {
        let coordinator = ServiceSupervisor()
        coordinator.markTunnelStarting()
        let generation = coordinator.tunnelGeneration
        XCTAssertTrue(coordinator.beginTunnelProbe())
        XCTAssertFalse(coordinator.beginTunnelProbe())
        coordinator.tunnelDidExit(at: Date(timeIntervalSince1970: 10))
        XCTAssertFalse(coordinator.finishTunnelProbe(.healthy, generation: generation))
        XCTAssertEqual(coordinator.tunnelHealth, .stopped)
        coordinator.markTunnelStarting()
        for _ in 0..<4 {
            coordinator.finishTunnelProbe(.remoteUnavailable, generation: coordinator.tunnelGeneration)
            XCTAssertFalse(coordinator.shouldRecycleOwnedTunnel)
        }
        coordinator.finishTunnelProbe(.remoteUnavailable, generation: coordinator.tunnelGeneration)
        XCTAssertTrue(coordinator.shouldRecycleOwnedTunnel)
        coordinator.finishTunnelProbe(.healthy, generation: coordinator.tunnelGeneration)
        XCTAssertFalse(coordinator.shouldRecycleOwnedTunnel)
        XCTAssertEqual(coordinator.tunnelHealth, .healthy)
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

    @MainActor
    func testAdoptedHealthyTunnelAndInFlightProbePreventDuplicateTunnelLaunch() {
        let coordinator = ServiceSupervisor()
        let now = Date(timeIntervalSince1970: 200)
        coordinator.finishProbe(.healthy)
        XCTAssertTrue(coordinator.mayLaunchTunnel(at: now))

        // While a tunnel probe is in flight, do not launch a competing ngrok agent.
        XCTAssertTrue(coordinator.beginTunnelProbe(at: now))
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now))

        // Adopting an already-verified tunnel keeps mayLaunchTunnel false.
        let probeGen = coordinator.tunnelGeneration
        XCTAssertTrue(coordinator.finishTunnelProbe(.healthy, generation: probeGen))
        XCTAssertEqual(coordinator.tunnelHealth, .healthy)
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now))

        // An outdated tunnel probe result from the earlier generation cannot overwrite .healthy.
        XCTAssertFalse(coordinator.finishTunnelProbe(.remoteUnavailable, generation: probeGen))
        XCTAssertEqual(coordinator.tunnelHealth, .healthy)

        // Restarting only the Python server preserves the verified tunnel status.
        coordinator.resetServerForRestart()
        XCTAssertEqual(coordinator.tunnelHealth, .healthy)
        XCTAssertFalse(coordinator.mayLaunchTunnel(at: now))

        // If the inspector is absent and no process is running (.stopped), launching is allowed again.
        coordinator.finishProbe(.healthy)
        XCTAssertTrue(coordinator.finishTunnelProbe(.stopped, generation: coordinator.tunnelGeneration))
        XCTAssertEqual(coordinator.tunnelHealth, .stopped)
        XCTAssertFalse(coordinator.shouldRecycleOwnedTunnel)
        XCTAssertTrue(coordinator.mayLaunchTunnel(at: now))
    }
}
