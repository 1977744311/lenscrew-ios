import Foundation
import Security

/// bridge 连接配置。
///
/// 口令是能驱动你 Mac 上 agent 的凭据，所以只进 Keychain，
/// 且限定 WhenUnlockedThisDeviceOnly：不进 iCloud 备份、不迁移到新设备。
/// 主机、端口、常用工作目录这些不敏感，放 UserDefaults。
struct BridgeSettings {
    var host: String
    var port: Int
    var token: String
    var workspaceRoots: [String]

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    var isComplete: Bool {
        !host.isEmpty && port > 0 && !token.isEmpty
    }

    static let placeholderRoot = "/Users/you/project"

    static func load() -> BridgeSettings {
        let defaults = UserDefaults.standard
        return BridgeSettings(
            host: defaults.string(forKey: Keys.host) ?? "",
            port: defaults.object(forKey: Keys.port) as? Int ?? 4311,
            token: KeychainToken.read() ?? "",
            workspaceRoots: defaults.stringArray(forKey: Keys.roots) ?? []
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Keys.host)
        defaults.set(port, forKey: Keys.port)
        defaults.set(workspaceRoots, forKey: Keys.roots)
        KeychainToken.write(token)
    }

    /// 记住用过的工作目录：手机上没法浏览 Mac 的文件系统，全靠手打，
    /// 不记住的话每次开会话都要重新输一遍长路径。
    mutating func remember(root: String) {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaceRoots.removeAll { $0 == trimmed }
        workspaceRoots.insert(trimmed, at: 0)
        workspaceRoots = Array(workspaceRoots.prefix(8))
        save()
    }

    private enum Keys {
        static let host = "bridge.host"
        static let port = "bridge.port"
        static let roots = "bridge.workspaceRoots"
    }
}

private enum KeychainToken {
    private static let service = "dev.steven.LensCrew.bridge"
    private static let account = "token"

    static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
