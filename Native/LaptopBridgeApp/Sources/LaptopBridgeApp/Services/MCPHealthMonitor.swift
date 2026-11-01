// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/MCPHealthMonitor.swift
import Foundation
import Darwin

/// A listening TCP port is not proof that the process is RelayOS.
/// Only a valid, token-authenticated local control response is trusted.
enum MCPHealthStatus: String, Equatable {
    case healthy
    case unreachable
    case unauthorized
    case unexpectedService
    case tokenUnavailable
}

struct MCPHealthMonitor {
    typealias Transport = (URLRequest) async throws -> (Int, Data)
    private let tokenProvider: () -> String?
    private let transport: Transport

    init(
        tokenProvider: @escaping () -> String? = MCPHealthMonitor.readLocalControlToken,
        transport: @escaping Transport = MCPHealthMonitor.defaultTransport
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    func probe() async -> MCPHealthStatus {
        guard let token = tokenProvider(), token.utf8.count >= 16 else {
            return .tokenUnavailable
        }
        do {
            let (status, body) = try await transport(Self.makeRequest(token: token))
            return Self.evaluate(status: status, data: body)
        } catch {
            return .unreachable
        }
    }

    static func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/control/status")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        return request
    }

    static func evaluate(status: Int, data: Data) -> MCPHealthStatus {
        if status == 401 || status == 403 { return .unauthorized }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["setup_complete"] is Bool,
              json["emergency_stop"] is Bool,
              json["pending_approvals"] is Int,
              json["capabilities"] is [String: Any],
              json["active_transport"] is String
        else { return .unexpectedService }
        return .healthy
    }

    static func readLocalControlToken() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".laptop-bridge/control.token").path
        var metadata = stat()
        // Never follow a symlink to read a credential. Refuse unexpected
        // ownership, directory, or group/world-accessible token files.
        guard lstat(file, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o077) == 0,
              let value = try? String(contentsOfFile: file, encoding: .utf8)
        else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func defaultTransport(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return (0, data)
        }
        return (http.statusCode, data)
    }
}
