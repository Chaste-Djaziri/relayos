// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPActions.swift
import Foundation
import CryptoKit

/// In-process native filesystem/terminal operations. Every mutation is
/// independently bound to a locally reviewed SHA256 of the exact JSON arguments.
/// The remote endpoint cannot approve its own request.
final class NativeMCPActions {
    enum ActionError: Error { case denied, invalid, notFound, tooLarge, conflict, failed }
    let authorization: NativeMCPAuthorization
    let approvals: NativeMCPApprovalStore
    let jobs = NativeMCPJobs()

    init(authorization: NativeMCPAuthorization, approvals: NativeMCPApprovalStore) {
        self.authorization = authorization
        self.approvals = approvals
    }

    private func value(_ args: [String: Any], _ name: String) throws -> String {
        guard let value = args[name] as? String, !value.isEmpty, value.utf8.count < 32768 else {
            throw ActionError.invalid
        }
        return value
    }

    private func project(_ args: [String: Any]) throws -> (String, String) {
        let session = try value(args, "session_id")
        let root = try value(args, "project_root")
        guard authorization.isProjectSessionActive(session, root: URL(fileURLWithPath: root)) else {
            throw ActionError.denied
        }
        return (session, root)
    }

    private func fileURL(_ args: [String: Any], path: String) throws -> URL {
        let (session, root) = try project(args)
        let resolver = NativeMCPProjectFiles(authorization: authorization)
        return try resolver.validatedPath(sessionID: session, projectRoot: root, relativePath: path)
    }

    private func canonicalArguments(_ args: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(args) else { throw ActionError.invalid }
        return try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
    }

    private func digest(kind: String, args: [String: Any]) throws -> String {
        let raw = try canonicalArguments(args)
        guard raw.count <= 32768 else { throw ActionError.tooLarge }
        var data = Data(kind.utf8)
        data.append(0)
        data.append(raw)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func label(kind: String, args: [String: Any]) -> String {
        if kind == "show_guidance" {
            return (args["message"] as? String ?? "Guidance").prefix(300).description
        }
        if kind == "screen_snapshot" { return "Capture the main display" }
        if kind == "start_guidance_session" { return "Start time-limited screen guidance" }
        if kind == "run_project_command" || kind == "start_project_command_job" {
            let argv = args["argv"] as? [String] ?? []
            return argv.joined(separator: " ").prefix(3200).description
        }
        let path = (args["path"] as? String ?? "unknown").prefix(220)
        let excerpt = (args["content"] as? String ?? args["search"] as? String ?? "")
            .prefix(300).description
        return "\(path) — preview: \(excerpt)"
    }

    /// Proposal is allowed remotely, but local UI alone can call decide().
    func propose(kind: String, args: [String: Any]) throws -> [String: Any] {
        guard ["write_project_file", "apply_project_patch", "run_project_command",
               "start_project_command_job", "screen_snapshot",
               "show_guidance", "start_guidance_session"].contains(kind) else { throw ActionError.invalid }
        _ = try project(args)
        try validate(kind: kind, args: args)
        let hash = try digest(kind: kind, args: args)
        let target = "\(kind): \(label(kind: kind, args: args)) [sha256:\(hash)]"
        let request = try approvals.enqueue(kind: kind, target: target)
        return ["request_id": request.id, "status": "pending_local_approval",
                "kind": kind, "target": target, "expires_at": request.expiresAt.timeIntervalSince1970]
    }

    private func validate(kind: String, args: [String: Any]) throws {
        if kind == "write_project_file" {
            let url = try fileURL(args, path: try value(args, "path"))
            guard let content = args["content"] as? String,
                  content.utf8.count <= 262_144, url.lastPathComponent != "." else {
                throw ActionError.tooLarge
            }
        } else if kind == "apply_project_patch" {
            let url = try fileURL(args, path: try value(args, "path"))
            _ = url
            guard (args["search"] as? String)?.isEmpty == false,
                  args["replacement"] is String else { throw ActionError.invalid }
        } else if kind == "screen_snapshot" {
            _ = try project(args)
        } else if kind == "start_guidance_session" {
            _ = try project(args)
            let duration = args["max_duration_seconds"] as? Int ?? 300
            guard (15...900).contains(duration) else { throw ActionError.invalid }
        } else if kind == "show_guidance" {
            _ = try project(args)
            guard let message = args["message"] as? String,
                  (1...600).contains(message.utf8.count),
                  let x = args["x"] as? Double, let y = args["y"] as? Double,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { throw ActionError.invalid }
        } else {
            let (_, root) = try project(args)
            let argv = try commandArguments(args)
            let cwd = try value(args, "cwd")
            let cwdURL = try fileURL(args, path: cwd)
            guard cwdURL.hasDirectoryPath || (try? cwdURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  URL(fileURLWithPath: root).standardizedFileURL.path.count > 1 else { throw ActionError.denied }
            _ = argv
        }
    }

    private func commandArguments(_ args: [String: Any]) throws -> [String] {
        guard let argv = args["argv"] as? [String],
              (1...64).contains(argv.count),
              argv.allSatisfy({ !$0.contains("\0") && $0.utf8.count < 8192 }),
              let executable = argv.first,
              executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw ActionError.invalid
        }
        // No implicit shell or PATH execution; the user must review the exact
        // absolute executable and every parameter in the local approval inbox.
        return argv
    }

    private func consume(kind: String, args: [String: Any], requestID: String) throws {
        let hash = try digest(kind: kind, args: args)
        let expected = "\(kind): \(label(kind: kind, args: args)) [sha256:\(hash)]"
        let consumed = try approvals.consume(id: requestID)
        guard consumed.kind == kind, consumed.target == expected else { throw ActionError.denied }
    }

    func execute(kind: String, args: [String: Any], requestID: String) throws -> [String: Any] {
        // Revalidate session, executable and path after approval because the
        // filesystem and project session could have changed meanwhile.
        try validate(kind: kind, args: args)
        try consume(kind: kind, args: args, requestID: requestID)
        try validate(kind: kind, args: args)
        if kind == "write_project_file" {
            let url = try fileURL(args, path: try value(args, "path"))
            guard let content = args["content"] as? String else { throw ActionError.invalid }
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
                throw ActionError.notFound
            }
            try Data(content.utf8).write(to: url, options: .atomic)
            return ["written": true, "path": url.path, "bytes": content.utf8.count]
        }
        if kind == "apply_project_patch" {
            let url = try fileURL(args, path: try value(args, "path"))
            let old = try String(contentsOf: url, encoding: .utf8)
            guard old.utf8.count <= 262_144 else { throw ActionError.tooLarge }
            let search = try value(args, "search")
            let replacement = args["replacement"] as? String ?? ""
            guard old.components(separatedBy: search).count == 2 else { throw ActionError.conflict }
            let result = old.replacingOccurrences(of: search, with: replacement)
            guard result.utf8.count <= 262_144 else { throw ActionError.tooLarge }
            try result.write(to: url, atomically: true, encoding: .utf8)
            return ["patched": true, "path": url.path]
        }
        if kind == "screen_snapshot" {
            return try NativeScreenCapture.snapshot()
        }
        if kind == "start_guidance_session" {
            return try NativeGuidanceSessions.shared.start(
                duration: TimeInterval(args["max_duration_seconds"] as? Int ?? 300))
        }
        if kind == "show_guidance" {
            let message = try value(args, "message")
            guard let x = args["x"] as? Double, let y = args["y"] as? Double else {
                throw ActionError.invalid
            }
            DispatchQueue.main.async {
                NativeGuidanceOverlay.shared.show(message: message,
                                                  normalizedX: x, normalizedY: y)
            }
            return ["scheduled": true, "message": "Native guidance overlay requested"]
        }
        let argv = try commandArguments(args)
        let (_, root) = try project(args)
        let cwd = try fileURL(args, path: try value(args, "cwd"))
        let session = try value(args, "session_id")
        let result = try jobs.start(sessionID: session, projectRoot: root,
                                    executable: argv[0], arguments: Array(argv.dropFirst()), cwd: cwd)
        if kind == "run_project_command" {
            // Commands are always asynchronous to keep the network loop responsive.
            return ["job_id": result, "status": "started", "read_with": "read_project_command_job"]
        }
        return ["job_id": result, "status": "started"]
    }

    func guidanceStatus(_ args: [String: Any]) throws -> [String: Any] {
        _ = try project(args)
        return NativeGuidanceSessions.shared.status(id: try value(args, "guidance_session_id"))
    }

    func guidanceCapture(_ args: [String: Any]) throws -> [String: Any] {
        _ = try project(args)
        return try NativeGuidanceSessions.shared.capture(id: try value(args, "guidance_session_id"))
    }

    func guidanceStop(_ args: [String: Any]) throws -> [String: Any] {
        _ = try project(args)
        NativeGuidanceSessions.shared.stop(id: try value(args, "guidance_session_id"))
        return ["stopped": true]
    }

    func clearGuidance() -> [String: Any] {
        DispatchQueue.main.async { NativeGuidanceSessions.shared.stopAll() }
        return ["cleared": true]
    }

    func readJob(_ args: [String: Any]) throws -> [String: Any] {
        let (session, _) = try project(args)
        return try jobs.read(id: try value(args, "job_id"), sessionID: session)
    }

    func cancelJob(_ args: [String: Any]) throws -> [String: Any] {
        let (session, _) = try project(args)
        try jobs.cancel(id: try value(args, "job_id"), sessionID: session)
        return ["cancel_requested": true]
    }
}

/// Only processes created by this instance can be cancelled. No shell or
/// management of arbitrary system processes occurs here.
final class NativeMCPJobs {
    enum JobError: Error { case missing, tooMany, failed }
    private struct Job {
        var id: String
        var session: String
        var process: Process
        var started: Date
        var status: String = "running"
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
    }
    private let lock = NSLock()
    private var records: [String: Job] = [:]
    private let maxOutput = 512_000

    func start(sessionID: String, projectRoot: String, executable: String,
               arguments: [String], cwd: URL) throws -> String {
        lock.lock()
        let active = records.values.filter { $0.status == "running" }.count
        lock.unlock()
        guard active < 4 else { throw JobError.tooMany }
        let id = UUID().uuidString
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = cwd
        task.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                            "LANG": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out; task.standardError = err
        lock.lock()
        records[id] = Job(id: id, session: sessionID, process: task, started: Date())
        lock.unlock()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.append(id: id, data: data, stderr: false)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.append(id: id, data: data, stderr: true)
        }
        task.terminationHandler = { [weak self] process in
            self?.finish(id: id, code: process.terminationStatus)
        }
        do { try task.run() }
        catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock(); records.removeValue(forKey: id); lock.unlock()
            throw JobError.failed
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
            try? self?.cancel(id: id, sessionID: sessionID)
        }
        return id
    }

    private func append(id: String, data: Data, stderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var job = records[id] else { return }
        if stderr {
            if job.stderr.count < maxOutput {
                job.stderr.append(data.prefix(maxOutput - job.stderr.count))
            }
        } else if job.stdout.count < maxOutput {
            job.stdout.append(data.prefix(maxOutput - job.stdout.count))
        }
        records[id] = job
    }

    private func finish(id: String, code: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard var job = records[id] else { return }
        job.status = code == 0 ? "completed" : "failed"
        job.exitCode = code
        records[id] = job
    }

    func read(id: String, sessionID: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let job = records[id], job.session == sessionID else { throw JobError.missing }
        return ["job_id": id, "status": job.status, "exit_code": job.exitCode.map { Int($0) } as Any? ?? NSNull(),
                "stdout": String(decoding: job.stdout, as: UTF8.self),
                "stderr": String(decoding: job.stderr, as: UTF8.self),
                "truncated": job.stdout.count >= maxOutput || job.stderr.count >= maxOutput]
    }

    func cancel(id: String, sessionID: String) throws {
        lock.lock()
        guard let job = records[id], job.session == sessionID else {
            lock.unlock(); throw JobError.missing
        }
        let process = job.process
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func shutdown() {
        lock.lock()
        let active = records.values.map(\.process)
        lock.unlock()
        for process in active where process.isRunning { process.terminate() }
    }
}
