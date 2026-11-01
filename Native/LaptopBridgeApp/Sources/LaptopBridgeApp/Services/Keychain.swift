import Foundation
import Security

enum Keychain {
    static let service = "rw.shangazi.laptop-bridge"

    static func read(account: String) -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum TokenStore {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".laptop-bridge/ngrok.token")
    }

    static func read() -> String? {
        if let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Keychain.read(account: "ngrok_authtoken")
    }

    static func write(_ value: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: url, options: .atomic)
    }
}
