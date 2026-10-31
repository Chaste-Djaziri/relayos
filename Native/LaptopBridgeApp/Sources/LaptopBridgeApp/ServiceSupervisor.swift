// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ServiceSupervisor.swift
import Foundation

/// Native service health and bounded recovery policy.
/// The owner app manages process lifetimes; this coordinator never kills or
/// adopts arbitrary processes and does not manufacture authorization tokens.
@MainActor
final class ServiceSupervisor {
    private let monitor: MCPHealthMonitor
    private(set) var generation = 0
    private var probeInProgress = false
    private var nextProbeAt = Date.distantPast
    private var serverFailures = 0
    private var tunnelFailures = 0
    private var serverRetryAt = Date.distantPast
    private var tunnelRetryAt = Date.distantPast
    private var tunnelProbeInProgress = false
    private var nextTunnelProbeAt = Date.distantPast
    private var consecutiveServerFailures = 0
    private var consecutiveTunnelFailures = 0
    private(set) var tunnelGeneration = 0
    private(set) var tunnelHealth: TunnelHealthStatus = .stopped

    private(set) var health: MCPHealthStatus = .unreachable

    init(monitor: MCPHealthMonitor = MCPHealthMonitor()) {
        self.monitor = monitor
    }

    func beginProbe(at now: Date = Date()) -> Bool {
        guard !probeInProgress, now >= nextProbeAt else { return false }
        probeInProgress = true
        nextProbeAt = now.addingTimeInterval(5)
        return true
    }

    func probe() async -> MCPHealthStatus {
        await monitor.probe()
    }

    @discardableResult
    func finishProbe(_ status: MCPHealthStatus, generation observedGeneration: Int? = nil) -> Bool {
        guard observedGeneration == nil || observedGeneration == generation else { return false }
        probeInProgress = false
        health = status
        if status == .healthy {
            serverFailures = 0
            consecutiveServerFailures = 0
            serverRetryAt = .distantPast
        } else if status == .unreachable {
            consecutiveServerFailures += 1
        } else {
            // An invalid token or unexpected service is an identity problem,
            // not proof that the app owns the listener. Never kill it.
            consecutiveServerFailures = 0
        }
        return true
    }

    func serverDidExit(at now: Date = Date()) {
        // A health response in flight might refer to the process that crashed.
        generation += 1
        probeInProgress = false
        nextProbeAt = .distantPast
        health = .unreachable
        consecutiveServerFailures = 0
        serverFailures += 1
        serverRetryAt = now.addingTimeInterval(Self.delay(for: serverFailures))
    }

    func serverLaunchFailed(at now: Date = Date()) {
        serverDidExit(at: now)
    }

    func tunnelDidExit(at now: Date = Date()) {
        tunnelGeneration += 1
        tunnelProbeInProgress = false
        nextTunnelProbeAt = .distantPast
        consecutiveTunnelFailures = 0
        tunnelHealth = .stopped
        tunnelFailures += 1
        tunnelRetryAt = now.addingTimeInterval(Self.delay(for: tunnelFailures))
    }

    func tunnelReady() {
        tunnelHealth = .healthy
        consecutiveTunnelFailures = 0
        tunnelFailures = 0
        tunnelRetryAt = .distantPast
    }

    /// A live but unresponsive *owned* child may be recycled after repeated
    /// failed authenticated probes. The caller must enforce ownership.
    var shouldRecycleOwnedServer: Bool { consecutiveServerFailures >= 5 }
    var shouldRecycleOwnedTunnel: Bool { consecutiveTunnelFailures >= 5 }

    func markTunnelStarting() {
        tunnelGeneration += 1
        tunnelProbeInProgress = false
        nextTunnelProbeAt = .distantPast
        consecutiveTunnelFailures = 0
        tunnelHealth = .connecting
    }

    func beginTunnelProbe(at now: Date = Date()) -> Bool {
        guard !tunnelProbeInProgress, now >= nextTunnelProbeAt else { return false }
        tunnelProbeInProgress = true
        nextTunnelProbeAt = now.addingTimeInterval(5)
        return true
    }

    @discardableResult
    func finishTunnelProbe(_ status: TunnelHealthStatus, generation observedGeneration: Int) -> Bool {
        guard observedGeneration == tunnelGeneration else { return false }
        tunnelProbeInProgress = false
        tunnelHealth = status
        if status == .healthy {
            tunnelReady()
        } else {
            consecutiveTunnelFailures += 1
        }
        return true
    }

    func mayLaunchServer(at now: Date = Date()) -> Bool {
        now >= serverRetryAt
    }

    func mayLaunchTunnel(at now: Date = Date()) -> Bool {
        health == .healthy && now >= tunnelRetryAt
    }

    func resetForManualRestart() {
        generation += 1
        probeInProgress = false
        nextProbeAt = .distantPast
        serverFailures = 0
        tunnelFailures = 0
        consecutiveServerFailures = 0
        consecutiveTunnelFailures = 0
        tunnelGeneration += 1
        tunnelProbeInProgress = false
        nextTunnelProbeAt = .distantPast
        tunnelHealth = .stopped
        serverRetryAt = .distantPast
        tunnelRetryAt = .distantPast
        health = .unreachable
    }

    static func delay(for failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 1), 6)
        return min(60, TimeInterval(1 << exponent))
    }
}
