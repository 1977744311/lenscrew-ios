import Foundation
import Security
import SwiftUI

/// 一台 Mac 的 bridge 连接配置。
/// 口令不在这里——它是能驱动那台 Mac 上 agent 的凭据，只进 Keychain（按主机各存一条）。
struct BridgeHostConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    /// 最近一次成功连上的时刻，设置页「上次连接 …」用
    var lastConnectedAt: Date?

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    static let defaultPort = 4311
}

/// 多主机配置仓：每台 Mac 跑自己的 bridge，这里管配置、口令与 active 切换。
///
/// 非敏感字段 JSON 存 UserDefaults（bridge.hosts.v1）；口令每主机一条 Keychain 记录
/// （service 不变，account = 主机 UUID），保持 WhenUnlockedThisDeviceOnly：
/// 不进 iCloud 备份、不迁移到新设备。
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [BridgeHostConfig] = []
    private(set) var activeHostID: UUID?
    /// 工作目录 MRU 是跨主机共享的：手机上全靠手打，能少输一次是一次
    private(set) var workspaceRoots: [String] = []

    var active: BridgeHostConfig? {
        hosts.first { $0.id == activeHostID }
    }

    init() {
        let defaults = UserDefaults.standard
        workspaceRoots = defaults.stringArray(forKey: Keys.roots) ?? []

        if let data = defaults.data(forKey: Keys.hosts),
           let decoded = try? JSONDecoder().decode([BridgeHostConfig].self, from: data) {
            hosts = decoded
            if let uuid = defaults.string(forKey: Keys.activeHost).flatMap(UUID.init) {
                activeHostID = uuid
            }
        } else {
            migrateLegacySingleHost()
        }
        // 存的 active 指向已删除的主机时退回第一台，不留悬空引用
        if active == nil { activeHostID = hosts.first?.id }
        persist()
    }

    // MARK: - 迁移

    /// 旧版是单主机配置（bridge.host/bridge.port + Keychain account "token"）。
    /// 首次载入时原样搬进列表，命名「我的 Mac」并设为 active；只跑一次——
    /// 跑完 bridge.hosts.v1 键就存在了，旧键随即清掉。
    private func migrateLegacySingleHost() {
        let defaults = UserDefaults.standard
        let legacyHost = defaults.string(forKey: Keys.legacyHost) ?? ""
        let legacyToken = HostKeychain.read(account: HostKeychain.legacyAccount) ?? ""
        guard !legacyHost.isEmpty || !legacyToken.isEmpty else { return }

        let config = BridgeHostConfig(
            id: UUID(),
            name: "我的 Mac",
            host: legacyHost,
            port: defaults.object(forKey: Keys.legacyPort) as? Int
                ?? BridgeHostConfig.defaultPort,
            lastConnectedAt: nil
        )
        hosts = [config]
        activeHostID = config.id
        HostKeychain.write(legacyToken, account: config.id.uuidString)
        HostKeychain.delete(account: HostKeychain.legacyAccount)
        defaults.removeObject(forKey: Keys.legacyHost)
        defaults.removeObject(forKey: Keys.legacyPort)
    }

    // MARK: - 主机操作

    @discardableResult
    func add(name: String, host: String, port: Int, token: String) -> BridgeHostConfig {
        let config = BridgeHostConfig(
            id: UUID(), name: name, host: host, port: port, lastConnectedAt: nil
        )
        hosts.append(config)
        HostKeychain.write(token, account: config.id.uuidString)
        if activeHostID == nil { activeHostID = config.id }
        persist()
        return config
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        HostKeychain.delete(account: id.uuidString)
        if activeHostID == id { activeHostID = hosts.first?.id }
        persist()
    }

    func setActive(_ id: UUID) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        activeHostID = id
        persist()
    }

    func markConnected(_ id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnectedAt = .now
        persist()
    }

    func token(for id: UUID) -> String {
        HostKeychain.read(account: id.uuidString) ?? ""
    }

    func setToken(_ token: String, for id: UUID) {
        HostKeychain.write(token, account: id.uuidString)
    }

    // MARK: - 工作目录 MRU

    /// 记住用过的工作目录：手机上没法浏览 Mac 的文件系统，全靠手打，
    /// 不记住的话每次开会话都要重新输一遍长路径。
    func remember(root: String) {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaceRoots.removeAll { $0 == trimmed }
        workspaceRoots.insert(trimmed, at: 0)
        workspaceRoots = Array(workspaceRoots.prefix(8))
        persist()
    }

    // MARK: - 持久化

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Keys.hosts)
        }
        if let activeHostID {
            defaults.set(activeHostID.uuidString, forKey: Keys.activeHost)
        } else {
            defaults.removeObject(forKey: Keys.activeHost)
        }
        defaults.set(workspaceRoots, forKey: Keys.roots)
    }

    private enum Keys {
        static let hosts = "bridge.hosts.v1"
        static let activeHost = "bridge.activeHost.v1"
        /// 沿用旧键：迁移后 MRU 数据原样保留
        static let roots = "bridge.workspaceRoots"
        static let legacyHost = "bridge.host"
        static let legacyPort = "bridge.port"
    }
}

/// 按主机存取口令。service 与旧版一致，account 用主机 UUID 区分。
private enum HostKeychain {
    private static let service = "dev.steven.LensCrew.bridge"
    /// 旧版单主机配置的 account 名，仅迁移时读一次
    static let legacyAccount = "token"

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String, account: String) {
        delete(account: account)
        guard !token.isEmpty else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
