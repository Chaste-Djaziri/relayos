import Foundation
import AppKit
import SwiftUI

@MainActor
final class BridgeModel: ObservableObject {
    static let shared = BridgeModel()

    // MARK: - Published Properties
    @Published var running = false
    @Published var mcpHealth: MCPHealthStatus = .unreachable
    @Published var tunnelRunning = false
    @Published var tunnelHealth: TunnelHealthStatus = .stopped
    @Published var serviceNotice = ""
    @Published var emergencyStop = false
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
    var inboxPollInFlight = false
    let arrivalTracker = ApprovalArrivalTracker()
    var commandJobStdoutOffset = 0
    var commandJobStderrOffset = 0
    var commandJobPollInFlight = false
    var commandOutputPollInFlight = false
    private var terminationObserver: NSObjectProtocol?

    // MARK: - Lifecycle
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".laptop-bridge/config.json")
        loadConfig()
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

    // MARK: - Navigation & Utility
    func showApprovalCenter() {
        approvalNavigationRequest += 1
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
    }
}
