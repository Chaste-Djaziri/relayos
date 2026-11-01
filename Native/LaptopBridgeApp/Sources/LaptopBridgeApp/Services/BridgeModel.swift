import Foundation
import AppKit
import SwiftUI

@MainActor
final class BridgeModel: ObservableObject {
    static let shared = BridgeModel()
    // Canvas/UI-only models never load the user's configuration or run helpers.
    let isPreview: Bool
    // Xcode Run uses the actual app model, not mock data, but never owns the
    // production server's process lease.
    var isDevelopmentClient: Bool {
        !isPreview && Bundle.main.bundleIdentifier == "pro.micorp.relayos.dev"
    }

    // MARK: - Published Properties
    @Published var running = false
    @Published var mcpHealth: MCPHealthStatus = .unreachable
    @Published var tunnelRunning = false
    @Published var tunnelHealth: TunnelHealthStatus = .stopped
    @Published var serviceNotice = ""
    @Published var emergencyStop = false
    @Published var emergencyStopInFlight = false
    @Published var endpoint = "Not configured"
    @Published var geminiConnected = false
    @Published var chatGPTConnected = false
    @Published var screenGuidance = false
    @Published var projectTools = false
    @Published var ngrokToken = ""
    @Published var ngrokDomainValue = ""
    @Published var ngrokInstallState = ""
    @Published var connectedClients: [String] = []
    @Published var permissionGrants: [[String: Any]] = []
    @Published var commandGrants: [SavedCommandGrant] = []
    @Published var commandJobs: [CommandJobEntry] = []
    @Published var selectedCommandJobID: String?
    @Published var commandJobOutput = ""
    @Published var commandJobError: String?
    @Published var commandGrantsBusy = false
    @Published var commandGrantDuplicateCount = 0
    @Published var commandGrantsError: String?
    @Published var approvalInbox: [ApprovalInboxItem] = []
    @Published var approvalNavigationRequest = 0
    @Published var approvalActivity: [ApprovalActivityEntry] = []
    @Published var approvalCenterError: String?
    @Published var approvalDecisionInFlight: String?

    // MARK: - Internal Dependencies & State
    let configURL: URL
    let supervisor = ServiceSupervisor()
    let tunnelMonitor = NgrokTunnelMonitor()
    let serverSlot = ManagedProcessSlot()
    let tunnelSlot = ManagedProcessSlot()
    var server: Process? {
        get { serverSlot.process }
        set { serverSlot.assign(newValue) }
    }
    var tunnel: Process? {
        get { tunnelSlot.process }
        set { tunnelSlot.assign(newValue) }
    }
    var shouldMaintainServices = false
    var preserveTunnelOnTermination = false
    var approvalTimer: DispatchSourceTimer?
    var developmentTimer: DispatchSourceTimer?
    private var developmentProbeInFlight = false
    var inboxPollInFlight = false
    let arrivalTracker = ApprovalArrivalTracker()
    var commandJobStdoutOffset = 0
    var commandJobStderrOffset = 0
    var commandJobPollInFlight = false
    var commandOutputPollInFlight = false
    private var terminationObserver: NSObjectProtocol?

    // MARK: - Lifecycle
    init(preview: Bool = false) {
        isPreview = preview
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".laptop-bridge/config.json")
        if preview { return }
        loadConfig()
        // Development instances observe the installed agent. Termination must
        // never invoke production service shutdown from the debug process.
        if isDevelopmentClient { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.shutdownServices() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Xcode development runtime (observe-only service supervision)
    func startDevelopmentObservation() {
        guard isDevelopmentClient, developmentTimer == nil else { return }
        serviceNotice = "Xcode development build: viewing the installed RelayOS service. Service ownership and restart are disabled."
        refreshApprovalInbox()
        refreshApprovalActivity()
        refreshConnectedClients()
        refreshPermissionGrants()
        refreshEmergencyStop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevelopmentHealth()
            }
        }
        timer.resume()
        developmentTimer = timer
    }

    func stopDevelopmentObservation() {
        developmentTimer?.cancel()
        developmentTimer = nil
    }

    private func refreshDevelopmentHealth() {
        guard isDevelopmentClient, !developmentProbeInFlight else { return }
        developmentProbeInFlight = true
        let endpointSnapshot = endpoint
        Task { @MainActor [weak self] in
            guard let self else { return }
            let local = await MCPHealthMonitor().probe()
            let remote = endpointSnapshot.hasPrefix("https://")
                ? await self.tunnelMonitor.probe(configuredEndpoint: URL(string: endpointSnapshot))
                : nil
            guard self.isDevelopmentClient else {
                self.developmentProbeInFlight = false
                return
            }
            self.mcpHealth = local
            self.running = local == .healthy
            self.tunnelHealth = remote?.status ?? .stopped
            // Monitoring an existing service doesn't confer process ownership.
            self.tunnelRunning = false
            self.developmentProbeInFlight = false
            self.refreshApprovalInbox()
        }
    }

    // MARK: - Navigation & Utility
    func showApprovalCenter() {
        approvalNavigationRequest += 1
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
    }
}
