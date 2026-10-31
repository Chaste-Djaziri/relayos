// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/SavedCommandGrant.swift
import Foundation

struct SavedCommandGrant: Decodable, Identifiable {
    let token: String
    let projectRoot: String
    let executable: String
    let workingDirectory: String
    let grantType: String
    let familyKey: String?
    let scopePrefix: [String]?
    let scopeFingerprint: String?
    let createdAt: Double
    let expiresAt: Double?

    var id: String { token }

    enum CodingKeys: String, CodingKey {
        case token, executable
        case projectRoot = "project_root"
        case workingDirectory = "working_directory"
        case grantType = "grant_type"
        case familyKey = "family_key"
        case scopePrefix = "scope_prefix"
        case scopeFingerprint = "scope_fingerprint"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    var scopeTitle: String {
        if let scopePrefix, !scopePrefix.isEmpty { return scopePrefix.joined(separator: " ") }
        if familyKey == "git:add" { return "git add" }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if let scopeFingerprint, !scopeFingerprint.isEmpty {
            return "Exact \(executableName) · #\(scopeFingerprint.prefix(8))"
        }
        return "Exact \(executableName) command"
    }
    var scopeDetails: String {
        if scopePrefix?.isEmpty == false || familyKey != nil { return "Trailing arguments may vary" }
        return "Exact arguments only · original arguments not retained for privacy"
    }
    var commandName: String { URL(fileURLWithPath: executable).lastPathComponent }
    var groupingKey: String { projectRoot + "\u{1F}" + executable }
    var durationTitle: String { grantType == "always" ? "Always allowed" : "For coding session" }
    func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.timeIntervalSince1970
    }
}
