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
            serverRetryAt = .distantPast
        }
        return true
    }

    func serverDidExit(at now: Date = Date()) {
        // A health response in flight might refer to the process that crashed.
        generation += 1
        probeInProgress = false
        nextProbeAt = .distantPast
        health = .unreachable
        serverFailures += 1
        serverRetryAt = now.addingTimeInterval(Self.delay(for: serverFailures))
    }

    func serverLaunchFailed(at now: Date = Date()) {
        serverDidExit(at: now)
    }

    func tunnelDidExit(at now: Date = Date()) {
        tunnelFailures += 1
        tunnelRetryAt = now.addingTimeInterval(Self.delay(for: tunnelFailures))
    }

    func tunnelReady() {
        tunnelFailures = 0
        tunnelRetryAt = .distantPast
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
        serverRetryAt = .distantPast
        tunnelRetryAt = .distantPast
        health = .unreachable
    }

    static func delay(for failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 1), 6)
        return min(60, TimeInterval(1 << exponent))
    }
}
