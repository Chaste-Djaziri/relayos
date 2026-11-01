import Foundation

extension BridgeModel {
    func refreshCommandJobs() {
        guard let helper = approvalExecutable(), !commandJobPollInFlight else { return }
        commandJobPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "list-command-jobs"]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            process.standardOutput = output
            do {
                try process.run()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
                let jobs = try JSONDecoder().decode([CommandJobEntry].self, from: data)
                Task { @MainActor [weak self] in
                    self?.commandJobs = jobs
                    self?.commandJobPollInFlight = false
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.commandJobError = error.localizedDescription
                    self?.commandJobPollInFlight = false
                }
            }
        }
    }

    func selectCommandJob(_ id: String) {
        guard selectedCommandJobID != id else { return }
        selectedCommandJobID = id
        commandJobStdoutOffset = 0
        commandJobStderrOffset = 0
        commandJobOutput = ""
        commandJobError = nil
        refreshCommandJobOutput()
    }

    func refreshCommandJobOutput() {
        guard let jobID = selectedCommandJobID,
              !commandOutputPollInFlight,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let encodedID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return }
        var components = URLComponents(string: "http://127.0.0.1:8765/control/command-job-output/\(encodedID)")!
        let stdoutOffset = commandJobStdoutOffset
        let stderrOffset = commandJobStderrOffset
        components.queryItems = [
            URLQueryItem(name: "stdout_offset", value: String(stdoutOffset)),
            URLQueryItem(name: "stderr_offset", value: String(stderrOffset))
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        commandOutputPollInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commandOutputPollInFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let output = try JSONDecoder().decode(CommandJobOutput.self, from: data)
                guard self.selectedCommandJobID == jobID else { return }
                self.commandJobStdoutOffset = output.stdoutOffset
                self.commandJobStderrOffset = output.stderrOffset
                if !output.stdout.isEmpty {
                    self.commandJobOutput += output.stdout
                }
                if !output.stderr.isEmpty {
                    self.commandJobOutput += output.stderr
                }
                if self.commandJobOutput.count > 80_000 {
                    self.commandJobOutput = String(self.commandJobOutput.suffix(80_000))
                }
                if output.outputUnavailable && self.commandJobOutput.isEmpty {
                    self.commandJobOutput = "Output unavailable after MCP server restart."
                }
            } catch {
                self.commandJobError = error.localizedDescription
            }
        }
    }

    func cancelCommandJob(_ jobID: String) {
        guard let helper = approvalExecutable() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["-m", "laptop_bridge.approvals", "cancel-command-job", jobID]
            self?.setApprovalWorkingDirectory(process, executable: helper)
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
                Task { @MainActor [weak self] in self?.refreshCommandJobs() }
            } catch {
                Task { @MainActor [weak self] in
                    self?.commandJobError = error.localizedDescription
                }
            }
        }
    }
}
