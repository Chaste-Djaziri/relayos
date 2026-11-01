import Foundation
import AppKit
import Darwin

extension BridgeModel {
    nonisolated private static func stopStaleRelayOSNgrokAgents() {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return }
        // Read pipe data before waitUntilExit to avoid filling the 64KB pipe buffer and deadlocking
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard let listing = String(data: data, encoding: .utf8) else { return }
        for line in listing.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            guard command == "/opt/homebrew/bin/ngrok http 127.0.0.1:8765" ||
                    command == "/usr/local/bin/ngrok http 127.0.0.1:8765" ||
                    command.hasPrefix("/opt/homebrew/bin/ngrok http 127.0.0.1:8765 --") ||
                    command.hasPrefix("/usr/local/bin/ngrok http 127.0.0.1:8765 --")
            else { continue }
            kill(pid_t(pid), SIGTERM)
        }
    }

    func shutdownServices(preserveTunnel: Bool = false) {
        if preserveTunnel {
            preserveTunnelOnTermination = true
        }
        shouldMaintainServices = false
        approvalTimer?.cancel()
        approvalTimer = nil
        if !preserveTunnelOnTermination {
            stopOwnedProcess(tunnel)
        }
        stopOwnedProcess(server)
        tunnel = nil
        server = nil
        running = false
        tunnelRunning = false
        tunnelHealth = .stopped
        mcpHealth = .unreachable
        supervisor.resetForManualRestart()
    }

    // Never wait for child processes on the UI actor. Shutdown is signalled
    // immediately and a bounded escalator runs away from the main thread.
    // ManagedProcessSlot ensures a late exit cannot clear a replacement child.
    func stopOwnedProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
    }

    func localServerIsListening() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(8765).bigEndian
        guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func startServices() {
        guard !isDevelopmentClient else { return }
        guard SingleInstanceCoordinator.shared.ownsLock else { return }
        shouldMaintainServices = true
        if approvalTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkOAuthApprovalsInBackground() }
            timer.resume()
            approvalTimer = timer
            refreshConnectedClients()
            refreshPermissionGrants()
        }
        guard server == nil else { return }
        if localServerIsListening() {
            running = false
            return
        }
        guard supervisor.mayLaunchServer() else { return }
        let process = Process()
        let bundledHelper = Bundle.main.resourceURL?
            .appendingPathComponent("Runtime/RelayOSMCPServer")
            .path
        let candidates = [bundledHelper, DevelopmentRuntimeLocator.pythonExecutable()?.path].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            supervisor.serverLaunchFailed()
            running = false
            NSLog("RelayOS MCP helper not found. Install the packaged app or set RELAYOS_DEV_ROOT.")
            return
        }
        let isBundledHelper = bundledHelper == executable
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = isBundledHelper ? [] : ["-m", "laptop_bridge.server"]
        if !isBundledHelper {
            process.currentDirectoryURL = DevelopmentRuntimeLocator.projectRoot()
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LAPTOP_BRIDGE_MCP_PORT"] = "8765"
        process.environment = environment
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.serverSlot.clearIfMatches(finished) else { return }
                self.running = false
                self.mcpHealth = .unreachable
                if self.shouldMaintainServices {
                    self.supervisor.serverDidExit()
                }
            }
        }
        do {
            try process.run()
            server = process
            running = false
        } catch {
            server = nil
            running = false
            supervisor.serverLaunchFailed()
            NSLog("RelayOS could not start MCP helper: %@", error.localizedDescription)
        }
    }

    func restartServices() {
        guard !isDevelopmentClient else { return }
        let ownsServer = server != nil
        stopOwnedProcess(tunnel)
        stopOwnedProcess(server)
        // Do not terminate unowned ngrok processes during a manual restart.
        server = nil
        tunnel = nil
        running = false
        tunnelRunning = false
        tunnelHealth = .stopped
        guard SingleInstanceCoordinator.shared.ownsLock else { return }
        supervisor.resetForManualRestart()
        mcpHealth = .unreachable
        if ownsServer {
            startServices()
        } else {
            running = false
        }
    }

    func restartPythonServer() {
        guard !isDevelopmentClient else { return }
        let owned = server != nil
        stopOwnedProcess(server)
        server = nil
        running = false
        mcpHealth = .unreachable
        supervisor.resetServerForRestart()
        if owned { startServices() }
    }

    func startTunnelIfConfigured() {
        guard !isDevelopmentClient else { return }
        guard SingleInstanceCoordinator.shared.ownsLock, mcpHealth == .healthy,
              supervisor.mayLaunchTunnel() else { return }
        guard tunnel == nil, let token = TokenStore.read() else { return }
        let executable = ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let executable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let domain = ngrokDomain()
        // Endpoint pooling is not a supported `ngrok http` CLI flag. Passing
        // it makes free endpoints fail or compete with a pre-existing tunnel.
        process.arguments = domain.map { ["http", "127.0.0.1:8765", "--url", "https://\($0)"] } ?? ["http", "127.0.0.1:8765"]
        var environment = ProcessInfo.processInfo.environment
        environment["NGROK_AUTHTOKEN"] = token
        process.environment = environment
        process.standardInput = Pipe()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.tunnelSlot.clearIfMatches(finished) else { return }
                self.tunnelRunning = false
                self.tunnelHealth = .stopped
                if self.shouldMaintainServices {
                    self.supervisor.tunnelDidExit()
                }
            }
        }
        do {
            supervisor.markTunnelStarting()
            try process.run()
            tunnel = process
            tunnelRunning = process.isRunning
            tunnelHealth = .connecting
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            tunnel = nil
            tunnelRunning = false
            tunnelHealth = .stopped
            supervisor.tunnelDidExit()
            NSLog("RelayOS could not start ngrok: %@", error.localizedDescription)
            return
        }
    }

    func adoptNgrokEndpoint(_ origin: String) {
        guard !isDevelopmentClient else { return }
        let clean = origin.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard clean.hasPrefix("https://") else { return }
        endpoint = clean + "/mcp"
        guard let data = try? Data(contentsOf: configURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard json["public_base_url"] as? String != clean else { return }
        json["public_base_url"] = clean
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? output.write(to: configURL, options: .atomic)
        }
        restartPythonServer()
    }

    func maintainServicesIfNeeded() {
        guard shouldMaintainServices, SingleInstanceCoordinator.shared.ownsLock else { return }

        if supervisor.beginProbe() {
            let observedGeneration = supervisor.generation
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await self.supervisor.probe()
                guard self.shouldMaintainServices,
                      SingleInstanceCoordinator.shared.ownsLock,
                      self.supervisor.finishProbe(status, generation: observedGeneration)
                else { return }
                self.mcpHealth = status
                self.running = status == .healthy
                if status != .healthy, self.tunnel != nil {
                    self.tunnelHealth = .connecting
                }
                self.probeTunnelIfNeeded()
                self.recoverServicesIfNeeded()
            }
        }
        probeTunnelIfNeeded()
        recoverServicesIfNeeded()
    }

    func probeTunnelIfNeeded() {
        // The tunnel can survive an app upgrade and still forward only to
        // RelayOS. Monitor its authenticated 401 response even when this app
        // did not create the Process instance, so the UI reports reality.
        guard mcpHealth == .healthy, ngrokIsConfigured(), supervisor.beginTunnelProbe() else { return }
        let observedTunnel = tunnel
        let generation = supervisor.tunnelGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let configuredEndpoint = URL(string: self.endpoint)
            let result = await self.tunnelMonitor.probe(configuredEndpoint: configuredEndpoint)
            guard self.shouldMaintainServices,
                  SingleInstanceCoordinator.shared.ownsLock,
                  self.tunnel === observedTunnel
            else { return }
            // An unavailable inspector does not prove the public route stopped.
            // Only a missing configured route and no owned child justify launch.
            // A previous public URL can still be configured after this app's
            // child tunnel exited. Do not let a 404/timeout from that stale
            // route suppress launch of a new owned tunnel; without an owned
            // child there is nothing safe to adopt or monitor.
            let effectiveStatus: TunnelHealthStatus = self.tunnel == nil
                ? .stopped : result.status
            guard self.supervisor.finishTunnelProbe(effectiveStatus, generation: generation) else { return }
            self.tunnelHealth = effectiveStatus
            // A reachable remote route is not proof we own the ngrok process.
            self.tunnelRunning = self.tunnel?.isRunning == true
            if let publicURL = result.publicURL {
                self.adoptNgrokEndpoint(publicURL.absoluteString)
            }
            self.recoverServicesIfNeeded()
        }
    }

    func recoverServicesIfNeeded() {
        guard shouldMaintainServices, SingleInstanceCoordinator.shared.ownsLock else { return }
        if supervisor.shouldRecycleOwnedServer, let ownedServer = server {
            serviceNotice = "Local MCP helper stopped responding; restarting it."
            stopOwnedProcess(ownedServer)
            server = nil
            running = false
            mcpHealth = .unreachable
            supervisor.serverDidExit()
        }
        if supervisor.shouldRecycleOwnedTunnel, let ownedTunnel = tunnel {
            serviceNotice = "Managed ngrok tunnel is unreachable; reconnecting."
            stopOwnedProcess(ownedTunnel)
            tunnel = nil
            tunnelRunning = false
            tunnelHealth = .stopped
            supervisor.tunnelDidExit()
        }
        if server == nil, !localServerIsListening(), supervisor.mayLaunchServer() {
            startServices()
        }
        if tunnel == nil, mcpHealth == .healthy, supervisor.mayLaunchTunnel() {
            startTunnelIfConfigured()
        }
        if mcpHealth == .healthy && tunnelHealth == .healthy {
            serviceNotice = ""
        }
    }
}
