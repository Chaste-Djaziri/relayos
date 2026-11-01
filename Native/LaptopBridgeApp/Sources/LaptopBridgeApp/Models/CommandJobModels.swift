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
