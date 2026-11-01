// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/CommandJobModels.swift
import Foundation

struct CommandJobEntry: Decodable, Identifiable {
    let id: String
    let projectRoot: String
    let workingDirectory: String
    let executableName: String
    let status: String
    let createdAt: TimeInterval
    let finishedAt: TimeInterval?
    let exitCode: Int?
    let outputBytes: Int
    let errorReason: String?
    let cancelRequested: Int
    let sessionID: String

    var active: Bool { status == "queued" || status == "running" }

    enum CodingKeys: String, CodingKey {
        case id, status
        case projectRoot = "project_root"
        case workingDirectory = "working_directory"
        case executableName = "executable_name"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case exitCode = "exit_code"
        case outputBytes = "output_bytes"
        case errorReason = "error_reason"
        case cancelRequested = "cancel_requested"
        case sessionID = "session_id"
    }
}

struct CommandJobOutput: Decodable {
    let stdout: String
    let stderr: String
    let stdoutOffset: Int
    let stderrOffset: Int
    let outputUnavailable: Bool

    enum CodingKeys: String, CodingKey {
        case stdout, stderr
        case stdoutOffset = "stdout_offset"
        case stderrOffset = "stderr_offset"
        case outputUnavailable = "output_unavailable"
    }
}


struct CommandJobListResponse: Decodable {
    let jobs: [CommandJobEntry]
}

/// Output is bounded in the UI independently of the MCP server's 4 MiB cap.
/// Keep stdout and stderr labels clear without implying exact interleaving
/// order across two distinct file descriptors.
enum CommandJobOutputFormatter {
    static let maxCharacters = 80_000

    static func append(existing: String, stdout: String, stderr: String) -> String {
        var combined = existing
        if !stdout.isEmpty {
            combined += stdout
        }
        if !stderr.isEmpty {
            if !combined.isEmpty && !combined.hasSuffix("\n") { combined += "\n" }
            combined += "[stderr] " + stderr
        }
        if combined.count > maxCharacters {
            combined = "… Earlier output omitted.\n" + String(combined.suffix(maxCharacters - 28))
        }
        return combined
    }
}

/// Real progress is only displayed when a program actually prints a percentage.
/// For jobs that do not report one, show elapsed time and streamed output bytes
/// rather than invent a percent-complete estimate.
enum CommandJobProgress {
    private static let percentagePattern = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?:100(?:\.0+)?|[0-9]{1,2}(?:\.[0-9]+)?)\s*%"#)

    static func percentage(in output: String) -> Double? {
        let tail = String(output.suffix(12_000))
        let full = NSRange(tail.startIndex..<tail.endIndex, in: tail)
        guard let match = percentagePattern.matches(in: tail, range: full).last,
              let range = Range(match.range, in: tail) else { return nil }
        let number = tail[range].replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percentage = Double(number), (0...100).contains(percentage) else { return nil }
        return percentage
    }

    static func elapsed(_ job: CommandJobEntry, at now: Date = Date()) -> TimeInterval {
        let end = job.finishedAt.map(Date.init(timeIntervalSince1970:)) ?? now
        return max(0, end.timeIntervalSince1970 - job.createdAt)
    }

    static func elapsedLabel(_ job: CommandJobEntry, at now: Date = Date()) -> String {
        let seconds = Int(elapsed(job, at: now))
        return seconds >= 3600
            ? String(format: "%dh %dm", seconds / 3600, (seconds % 3600) / 60)
            : String(format: "%dm %ds", seconds / 60, seconds % 60)
    }
}
