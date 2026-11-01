// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/ApprovalCenterModels.swift
import Foundation

struct ApprovalInboxItem: Decodable, Identifiable, Equatable {
    struct Context: Decodable, Equatable {
        let cwd: String?
        let requestedGrant: String?
        let commandFamily: String?
        let scopePrefix: [String]?
        let clientID: String?
        let sessionID: String?

        enum CodingKeys: String, CodingKey {
            case cwd
            case requestedGrant = "requested_grant"
            case commandFamily = "command_family"
            case scopePrefix = "scope_prefix"
            case clientID = "client_id"
            case sessionID = "session_id"
        }
    }

    let requestID: String
    let kind: String
    let target: String
    let argv: [String]
    let context: Context
    let createdAt: TimeInterval
    let expiresAt: TimeInterval

    var id: String { requestID }
    var isOAuth: Bool { kind == "oauth_connection" }
    var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt }

    var title: String {
        if isOAuth { return "Connect \(target)" }
        if let scope = context.scopePrefix, !scope.isEmpty { return scope.joined(separator: " ") }
        if context.commandFamily == "git:add" { return "git add" }
        if let first = argv.first { return URL(fileURLWithPath: first).lastPathComponent }
        return kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var scopeDescription: String {
        if isOAuth { return "MCP access requires a local one-time approval." }
        if context.scopePrefix?.isEmpty == false || context.commandFamily != nil {
            return "Session / Always: the shown prefix is fixed; later arguments may change."
        }
        return "Only the exact requested command is covered."
    }

    enum CodingKeys: String, CodingKey {
        case kind, target, argv, context
        case requestID = "request_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct ApprovalActivityEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let recordedAt: TimeInterval
    let kind: String
    let target: String
    let decision: String
    let exitCode: Int?
    let durationMS: Int?

    static func == (lhs: ApprovalActivityEntry, rhs: ApprovalActivityEntry) -> Bool {
        lhs.id == rhs.id
    }

    var summaryTitle: String {
        switch kind {
        case "project_command":
            switch decision {
            case "executed": return "Command Executed"
            case "requested": return "Command Execution Requested"
            case "denied": return "Command Execution Denied"
            case "expired": return "Command Request Expired"
            default:
                if decision.starts(with: "approved") { return "Command Approved" }
                return "Command \(decision.capitalized)"
            }
        case "oauth_authorization", "oauth_connection":
            switch decision {
            case "requested": return "OAuth Access Requested"
            case "approved": return "OAuth Client Connected"
            case "denied": return "OAuth Access Denied"
            case "expired": return "OAuth Request Expired"
            default: return "OAuth \(decision.capitalized)"
            }
        case "project_session":
            switch decision {
            case "approved": return "Workspace Session Approved"
            case "persistent_grant_reused": return "Workspace Access Reused"
            case "denied": return "Workspace Session Denied"
            default: return "Workspace Session \(decision.capitalized)"
            }
        case "command_job":
            switch decision {
            case "queued": return "Terminal Job Queued"
            case "running": return "Terminal Job Started"
            case "completed": return "Terminal Job Completed"
            case "failed": return "Terminal Job Failed"
            case "cancelled": return "Terminal Job Cancelled"
            case "interrupted": return "Terminal Job Interrupted"
            default: return "Terminal Job \(decision.capitalized)"
            }
        case "command_grant":
            return "Persistent Grant \(decision.replacingOccurrences(of: "_", with: " ").capitalized)"
        case "command_grant_cleanup":
            return "Redundant Grants Cleaned"
        default:
            return "\(kind.replacingOccurrences(of: "_", with: " ").capitalized) · \(decision.capitalized)"
        }
    }

    var summarySubtitle: String {
        var parts: [String] = []
        if kind == "project_command" && target.contains(":") {
            let split = target.split(separator: ":", maxSplits: 1).map(String.init)
            if split.count == 2 {
                let executable = URL(fileURLWithPath: split[1]).lastPathComponent
                parts.append(executable)
                parts.append(split[0])
            } else {
                parts.append(target)
            }
        } else {
            parts.append(target)
        }

        if let duration = formattedDuration {
            parts.append(duration)
        }

        return parts.joined(separator: " · ")
    }

    var systemIcon: String {
        switch kind {
        case "project_command":
            return "terminal"
        case "oauth_authorization", "oauth_connection":
            return "link"
        case "project_session":
            return "folder"
        case "command_job":
            return "play.terminal"
        default:
            return "clock.arrow.circlepath"
        }
    }

    var formattedDuration: String? {
        guard let ms = durationMS else { return nil }
        if ms < 1000 {
            return "\(ms) ms"
        } else {
            return String(format: "%.2f s", Double(ms) / 1000.0)
        }
    }

    var formattedExitCode: String? {
        guard let code = exitCode else { return nil }
        return code == 0 ? "0 (Success)" : "\(code) (Failed)"
    }

    var parsedProjectDirectory: String? {
        if target.contains(":") {
            let split = target.split(separator: ":", maxSplits: 1).map(String.init)
            if split.count == 2 {
                return split[0]
            }
        }
        if kind == "project_session" {
            return target
        }
        return nil
    }

    var parsedExecutable: String? {
        if target.contains(":") {
            let split = target.split(separator: ":", maxSplits: 1).map(String.init)
            if split.count == 2 {
                return split[1]
            }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, target, decision
        case recordedAt = "recorded_at"
        case exitCode = "exit_code"
        case durationMS = "duration_ms"
    }
}
