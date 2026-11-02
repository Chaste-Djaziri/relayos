// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/BridgeModel+ScreenSharing.swift
import Foundation

/// A local-only, time-bounded, explicitly enabled screen-sharing session.
/// The MCP client cannot activate this permission. No token or screenshot
/// contents are stored in UserDefaults or transmitted by this UI component.
struct RelayOSScreenSharingStatus: Decodable {
    let active: Bool
    let expiresInSeconds: Int
    let scope: String
    let target: String

    enum CodingKeys: String, CodingKey {
        case active, scope, target
        case expiresInSeconds = "expires_in_seconds"
    }
}

extension BridgeModel {
    var screenSharingSummary: String {
        guard screenSharingActive && screenSharingSecondsRemaining > 0 else {
            return "Off"
        }
        let minutes = (screenSharingSecondsRemaining + 59) / 60
        return "On · \(minutes) min left"
    }

    func refreshScreenSharing() {
        guard !isPreview, !isSwiftOnly, !screenSharingBusy,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/screen-sharing")
        else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.screenSharingActive = false
                    self.screenSharingSecondsRemaining = 0
                    return
                }
                let status = try JSONDecoder().decode(RelayOSScreenSharingStatus.self, from: data)
                self.screenSharingActive = status.active
                self.screenSharingSecondsRemaining = status.expiresInSeconds
            } catch {
                self.screenSharingActive = false
                self.screenSharingSecondsRemaining = 0
            }
        }
    }

    /// Invoked only by a user pressing Start/Stop in the native RelayOS UI.
    /// The authenticated local control endpoint enforces duration and revocation.
    func setScreenSharing(_ enabled: Bool) {
        guard !isPreview, !isDevelopmentClient, !screenSharingBusy,
              let token = MCPHealthMonitor.readLocalControlToken(),
              let url = URL(string: "http://127.0.0.1:8765/control/screen-sharing")
        else {
            screenSharingError = "The installed RelayOS agent is required to manage sharing."
            return
        }
        screenSharingBusy = true
        screenSharingError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-relayos-control-token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "enabled": enabled, "duration_seconds": 1800
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.screenSharingBusy = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.screenSharingError = "RelayOS did not accept the sharing request."
                    return
                }
                let result = try JSONDecoder().decode(RelayOSScreenSharingStatus.self, from: data)
                self.screenSharingActive = result.active
                self.screenSharingSecondsRemaining = result.expiresInSeconds
                self.screenSharingError = nil
            } catch {
                self.screenSharingError = "Unable to update screen sharing: \(error.localizedDescription)"
            }
        }
    }
}
