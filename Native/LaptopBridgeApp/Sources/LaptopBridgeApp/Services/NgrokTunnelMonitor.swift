// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/NgrokTunnelMonitor.swift
import Foundation

enum TunnelHealthStatus: String, Equatable {
    case stopped
    case connecting
    case healthy
    case inspectorUnavailable
    case remoteUnavailable
    case unexpectedEndpoint

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .connecting: return "Connecting"
        case .healthy: return "Verified public MCP (401)"
        case .inspectorUnavailable: return "Inspector unavailable"
        case .remoteUnavailable: return "Public endpoint unreachable"
        case .unexpectedEndpoint: return "Unrecognized tunnel"
        }
    }
}

struct NgrokTunnelProbe: Equatable {
    let status: TunnelHealthStatus
    let publicURL: URL?
}

/// Inspect the app-owned ngrok tunnel and then verify the public MCP route.
/// The unauthenticated endpoint should return HTTP 401, proving that a remote
/// request reaches RelayOS authentication rather than an ngrok 404 page.
struct NgrokTunnelMonitor {
    typealias Transport = (URLRequest) async throws -> (Int, Data)
    private let transport: Transport

    init(transport: @escaping Transport = NgrokTunnelMonitor.defaultTransport) {
        self.transport = transport
    }

    func probe(configuredEndpoint: URL? = nil) async -> NgrokTunnelProbe {
        let url = URL(string: "http://127.0.0.1:4040/api/tunnels")!
        var inspector = URLRequest(url: url)
        inspector.timeoutInterval = 2
        inspector.cachePolicy = .reloadIgnoringLocalCacheData
        let body: Data
        do {
            let (status, data) = try await transport(inspector)
            guard status == 200 else {
                return await probeConfiguredEndpoint(configuredEndpoint)
            }
            body = data
        } catch {
            return await probeConfiguredEndpoint(configuredEndpoint)
        }
        guard let publicURL = Self.ownedEndpoint(from: body) else {
            // Another application may own the inspector on port 4040. We
            // cannot adopt that tunnel, but we may still verify our own
            // previously stored exact HTTPS endpoint independently.
            let known = await probeConfiguredEndpoint(configuredEndpoint)
            return known.status == .healthy
                ? known : .init(status: .unexpectedEndpoint, publicURL: nil)
        }
        return await verifyPublicEndpoint(publicURL)
    }

    // The configured HTTPS endpoint can remain accessible after a process
    // handover even when ngrok's optional localhost inspector is unavailable.
    // Only a previously configured exact /mcp URL may be used as this fallback;
    // a caller cannot supply an arbitrary URL or trigger unapproved adoption.
    private func probeConfiguredEndpoint(_ endpoint: URL?) async -> NgrokTunnelProbe {
        guard let endpoint, endpoint.scheme == "https",
              endpoint.user == nil, endpoint.password == nil,
              endpoint.port == nil, endpoint.path == "/mcp",
              endpoint.query == nil, endpoint.fragment == nil,
              let host = endpoint.host, !host.isEmpty,
              let origin = URL(string: "https://\(host)") else {
            return .init(status: .inspectorUnavailable, publicURL: nil)
        }
        return await verifyPublicEndpoint(origin)
    }

    private func verifyPublicEndpoint(_ origin: URL) async -> NgrokTunnelProbe {
        var request = URLRequest(url: origin.appendingPathComponent("mcp"))
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (status, _) = try await transport(request)
            return .init(status: status == 401 ? .healthy : .remoteUnavailable,
                         publicURL: status == 401 ? origin : nil)
        } catch {
            return .init(status: .remoteUnavailable, publicURL: nil)
        }
    }

    /// Only inspect a tunnel forwarding to this app's loopback listener. Never
    /// adopt an arbitrary tunnel from another application using ngrok port 4040.
    static func ownedEndpoint(from data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnels = json["tunnels"] as? [[String: Any]]
        else { return nil }
        for tunnel in tunnels {
            guard let text = tunnel["public_url"] as? String,
                  let url = URL(string: text),
                  url.scheme == "https",
                  url.user == nil, url.password == nil,
                  url.port == nil, url.path.isEmpty || url.path == "/",
                  let host = url.host, !host.isEmpty,
                  let configuration = tunnel["config"] as? [String: Any],
                  let address = configuration["addr"] as? String,
                  Self.isRelayOSForwardTarget(address)
            else { continue }
            return url
        }
        return nil
    }

    private static func isRelayOSForwardTarget(_ text: String) -> Bool {
        let target = text.hasPrefix("http://") ? String(text.dropFirst(7)) : text
        return target == "127.0.0.1:8765" || target == "localhost:8765"
    }

    private static func defaultTransport(_ request: URLRequest) async throws -> (Int, Data) {
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}
