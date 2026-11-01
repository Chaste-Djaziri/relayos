import Foundation
import AppKit

extension BridgeModel {
    func setEmergencyStop(_ value: Bool) {
        guard !emergencyStopInFlight, emergencyStop != value else { return }
        guard let helper = approvalExecutable() else {
            showSecurityError("RelayOS authorization helper is unavailable.")
            return
        }
        emergencyStopInFlight = true
        // Fail closed: keep the last backend-confirmed state until the helper
        // independently acknowledges the requested change.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "set-emergency-stop", value ? "true" : "false"]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            let pipe = Pipe()
            process.standardOutput = pipe
            var confirmed: Bool?
            do {
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    confirmed = json["emergency_stop"] as? Bool
                }
            } catch {
                // The UI must not claim a successful revocation without proof.
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.emergencyStopInFlight = false
                if confirmed == value {
                    self.emergencyStop = value
                } else {
                    self.showSecurityError("The agent did not confirm the requested emergency-stop state.")
                }
            }
        }
    }

    func showSecurityError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "RelayOS security action failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    nonisolated func refreshEmergencyStop() {
        guard let python = approvalExecutable() else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "laptop_bridge.approvals", "emergency-stop-status"]
        setApprovalWorkingDirectory(process, executable: python)
        process.standardOutput = pipe
        try? process.run()
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["emergency_stop"] as? Bool else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.emergencyStop != enabled {
                self?.emergencyStop = enabled
            }
        }
    }

    nonisolated func refreshConnectedClients() {
        guard let python = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-grants"]
            self?.setApprovalWorkingDirectory(process, executable: python)
            process.standardOutput = pipe
            try? process.run()
            let data = try? pipe.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            guard let data,
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let names = items.compactMap { $0["client_name"] as? String }
            DispatchQueue.main.async { [weak self] in
                self?.connectedClients = names
            }
        }
    }

    nonisolated func refreshPermissionGrants() {
        guard let python = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-permissions"]
            self?.setApprovalWorkingDirectory(process, executable: python)
            process.standardOutput = pipe
            try? process.run()
            let data = try? pipe.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            guard let data,
                  let grants = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            DispatchQueue.main.async { [weak self] in
                self?.permissionGrants = grants
            }
        }
    }

    func revokePermission(_ id: String) {
        revokePermissions([id])
    }

    func revokePermissions(_ ids: [String]) {
        guard let helper = approvalExecutable(), !ids.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for id in ids {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: helper)
                process.arguments = ["-m", "laptop_bridge.approvals", "revoke-permission", id]
                self?.setApprovalWorkingDirectory(process, executable: helper)
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 { break }
                } catch { break }
            }
            Task { @MainActor [weak self] in
                self?.refreshPermissionGrants()
            }
        }
    }

    func refreshCommandGrants() {
        guard let executable = approvalExecutable() else {
            commandGrantsError = "RelayOS approval helper could not be found."
            return
        }
        guard !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-command-grants"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "Could not read command grants."])
                }
                let grants = try JSONDecoder().decode([SavedCommandGrant].self, from: data)
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrants = grants
                    self?.commandGrantsBusy = false
                    self?.refreshCommandGrantDuplicateCount()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }

    func refreshCommandGrantDuplicateCount() {
        guard let executable = approvalExecutable() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "command-grant-duplicates"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let duplicates = result["duplicates"] else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantDuplicateCount = duplicates
                }
            } catch {
                // A temporary read failure must not revoke or change anything.
            }
        }
    }

    func cleanupDuplicateCommandGrants() {
        guard let executable = approvalExecutable(), !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "cleanup-command-grant-duplicates"]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = output
            do {
                try process.run()
                _ = try? output.fileHandleForReading.readToEnd()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "Could not clean duplicate approvals."])
                }
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsBusy = false
                    self?.refreshCommandGrants()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }

    func revokeCommandGrant(_ id: String) {
        guard let executable = approvalExecutable() else {
            commandGrantsError = "RelayOS approval helper could not be found."
            return
        }
        guard !commandGrantsBusy else { return }
        commandGrantsBusy = true
        commandGrantsError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-m", "laptop_bridge.approvals", "revoke-command-grant", id]
            self?.setApprovalWorkingDirectory(process, executable: executable)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
                _ = try? stdoutPipe.fileHandleForReading.readToEnd()
                _ = try? stderrPipe.fileHandleForReading.readToEnd()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "RelayOS", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "The approval could not be revoked."])
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.commandGrants.removeAll { $0.id == id }
                    self.commandGrantsBusy = false
                    self.refreshCommandGrants()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.commandGrantsError = error.localizedDescription
                    self?.commandGrantsBusy = false
                }
            }
        }
    }
}
