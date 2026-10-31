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

struct ApprovalActivityEntry: Decodable, Identifiable {
    let id: Int
    let recordedAt: TimeInterval
    let kind: String
    let target: String
    let decision: String
    let exitCode: Int?
    let durationMS: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind, target, decision
        case recordedAt = "recorded_at"
        case exitCode = "exit_code"
        case durationMS = "duration_ms"
    }
}
