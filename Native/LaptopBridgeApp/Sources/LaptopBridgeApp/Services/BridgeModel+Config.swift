import Foundation
import AppKit

extension BridgeModel {
    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let base = json["public_base_url"] as? String, base.hasPrefix("https://"), !base.contains("/docs/"), !base.isEmpty {
            endpoint = base + "/mcp"
        }
        if let caps = json["capabilities"] as? [String: Any] {
            screenGuidance = caps["screen_guidance"] as? Bool ?? false
            projectTools = caps["project_tools"] as? Bool ?? false
        }
    }

    func saveCapabilities() {
        guard let data = try? Data(contentsOf: configURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["capabilities"] = [
            "system_status": true,
            "screen_guidance": screenGuidance,
            "project_tools": projectTools
        ]
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let dir = configURL.deletingLastPathComponent() as URL? {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? output.write(to: configURL, options: .atomic)
        }
        restartServices()
    }

    func ngrokDomain() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ngrok = json["ngrok"] as? [String: Any],
              let domain = ngrok["domain"] as? String,
              !domain.isEmpty else { return nil }
        return domain
    }

    func installNgrok() {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ngrok") ||
            FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ngrok") {
            ngrokInstallState = "ngrok is already installed."
            return
        }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let brew else {
            ngrokInstallState = "Homebrew was not found. Install it from brew.sh."
            return
        }
        ngrokInstallState = "Installing ngrok…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "ngrok/ngrok/ngrok"]
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.ngrokInstallState = process.terminationStatus == 0
                    ? "ngrok installed successfully."
                    : "ngrok installation failed. Try again or use Terminal."
            }
        }
        try? process.run()
    }

    func configureNgrok() {
        let domain = ngrokDomainValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !ngrokToken.isEmpty else { return }
        guard domain.isEmpty || (domain.contains(".") && !domain.contains("/")) else { return }
        TokenStore.write(ngrokToken)
        var json = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: configURL)) ?? Data())) as? [String: Any] ?? [:]
        json["public_base_url"] = domain.isEmpty ? "" : "https://\(domain)"
        json["active_transport"] = "ngrok"
        json["setup_complete"] = true
        json["ngrok"] = [
            "enabled": true,
            "domain": domain,
            "region": "",
            "config_path": "",
            "agent_version": ""
        ]
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: configURL, options: .atomic)
        }
        endpoint = domain.isEmpty ? "Waiting for ngrok…" : "https://\(domain)/mcp"
        ngrokToken = ""
        restartServices()
    }
}
