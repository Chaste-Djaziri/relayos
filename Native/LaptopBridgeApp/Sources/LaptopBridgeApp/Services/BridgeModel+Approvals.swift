import Foundation
import AppKit

extension BridgeModel {
    nonisolated func approvalExecutable() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Runtime/RelayOSApprovals").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return DevelopmentRuntimeLocator.pythonExecutable()?.path
    }

    nonisolated func setApprovalWorkingDirectory(_ process: Process, executable: String) {
        if executable.contains("/Contents/Resources/Runtime/") {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        } else {
            process.currentDirectoryURL = DevelopmentRuntimeLocator.projectRoot()
        }
    }

    func refreshApprovalInbox() {
        guard !inboxPollInFlight, let helper = approvalExecutable() else { return }
        inboxPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-inbox"]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = pipe
            do {
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOSInbox", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not load approvals."])
                }
                let items = try JSONDecoder().decode([ApprovalInboxItem].self, from: data)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let newlyArrived = self.arrivalTracker.newlyObserved(items)
                    self.approvalInbox = items
                    self.approvalCenterError = nil
                    self.inboxPollInFlight = false
                    if !newlyArrived.isEmpty {
                        ApprovalSound.playIfEnabled()
                        for item in newlyArrived { ApprovalArrivalNotification.deliver(item) }
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.approvalCenterError = error.localizedDescription
                    self?.inboxPollInFlight = false
                }
            }
        }
    }

    func refreshApprovalActivity(search: String = "") {
        guard let helper = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "activity-history",
                                 "--limit", "150", "--search", search]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return }
                let events = try JSONDecoder().decode([ApprovalActivityEntry].self, from: data)
                Task { @MainActor [weak self] in self?.approvalActivity = events }
            } catch {
                Task { @MainActor [weak self] in self?.approvalCenterError = error.localizedDescription }
            }
        }
    }

    func decideApproval(_ item: ApprovalInboxItem, decision: String) {
        guard approvalDecisionInFlight == nil, !item.isExpired,
              let helper = approvalExecutable() else {
            approvalCenterError = "Request expired or another decision is in progress."
            refreshApprovalInbox()
            return
        }
        guard ["once", "session", "persistent", "deny"].contains(decision),
              (!item.isOAuth || decision == "once" || decision == "deny") else { return }
        approvalDecisionInFlight = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals",
                                 "decide-inbox", item.id, decision]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOSInbox", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Request expired, was denied, or could not be decided."])
                }
                Task { @MainActor [weak self] in
                    self?.approvalDecisionInFlight = nil
                    self?.approvalInbox.removeAll { $0.id == item.id }
                    self?.approvalCenterError = nil
                    self?.refreshApprovalInbox()
                    self?.refreshApprovalActivity()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.approvalDecisionInFlight = nil
                    self?.approvalCenterError = error.localizedDescription
                    self?.refreshApprovalInbox()
                }
            }
        }
    }

    nonisolated func checkOAuthApprovalsInBackground() {
        Task { @MainActor [weak self] in
            self?.maintainServicesIfNeeded()
            self?.refreshApprovalInbox()
        }
        refreshConnectedClients()
        refreshPermissionGrants()
        refreshEmergencyStop()
    }
}
