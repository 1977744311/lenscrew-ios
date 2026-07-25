import BridgeLink
import Foundation
import Security
import SwiftUI

/// 一台 Mac 的 bridge 连接配置，两种形态共用一个结构：
/// - manual：host/port + 口令（口令是能驱动那台 Mac 上 agent 的凭据，只进 Keychain）；
/// - paired：扫码配对来的，macDeviceId 非空即是。mac 身份公钥（trusted_reconnect 的
///   信任根）也只进 Keychain（account "mac-identity-<id>"），这里只留可公开的地址簿。
/// 配对字段全部可选，旧版 JSON（只有前五个字段）解码出来自然是 manual 形态。
struct BridgeHostConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    /// 最近一次成功连上的时刻，设置页「上次连接 …」用
    var lastConnectedAt: Date?
    /// 非空 = paired 形态，也是 relay 的 roomId
    var macDeviceId: String?
    var lanHost: String?
    var lanPort: Int?
    /// relay 服务的 https 地址（原样存二维码里的字符串）
    var relay: String?

    var isPaired: Bool { macDeviceId != nil }

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    var lanBaseURL: URL? {
        guard let lanHost, let lanPort, !lanHost.isEmpty, lanPort > 0 else { return nil }
        return URL(string: "http://\(lanHost):\(lanPort)")
    }

    var relayURL: URL? {
        relay.flatMap(URL.init(string:))
    }

    static let defaultPort = 4311
}

/// 已配对主机实际走的链路，设置页主机行 / Home 主机 chip 的副行展示用
enum HostLinkPath: Sendable, Equatable {
    case direct, relay

    var label: String {
        switch self {
        case .direct: return "直连"
        case .relay: return "中继"
        }
    }
}

extension BridgeHostConfig {
    /// paired 主机的候选 E2EE 端点：LAN 直连优先，relay 兜底；manual 主机返回空。
    /// mac 公钥由调用方从 Keychain 取出传入，这里不碰存储。
    func pairedEndpoints(
        macIdentityPublicKey: String
    ) -> [(endpoint: SecureBridgeEndpoint, path: HostLinkPath)] {
        guard let macDeviceId else { return [] }
        let trusted = TrustedMac(
            macDeviceId: macDeviceId,
            macIdentityPublicKey: macIdentityPublicKey,
            displayName: name
        )
        let phone = PhonePairingIdentity.shared
        var result: [(SecureBridgeEndpoint, HostLinkPath)] = []
        if let lanBaseURL {
            result.append((
                SecureBridgeEndpoint(
                    transport: .direct(baseURL: lanBaseURL),
                    phoneDeviceId: phone.deviceId,
                    phoneIdentity: phone.identity,
                    trustedMac: trusted
                ), .direct
            ))
        }
        if let relayURL {
            result.append((
                SecureBridgeEndpoint(
                    transport: .relay(relayURL: relayURL, roomId: macDeviceId),
                    phoneDeviceId: phone.deviceId,
                    phoneIdentity: phone.identity,
                    trustedMac: trusted
                ), .relay
            ))
        }
        return result
    }
}

/// 敏感字段（口令 / mac 身份公钥）的存取抽象。生产实现是 Keychain
/// （KeychainSecretStore）；单测在无签名构建（CODE_SIGNING_ALLOWED=NO）下拿不到
/// keychain entitlement，注入内存实现。契约与 Keychain 版一致：写空串等价删除。
protocol HostSecretStoring {
    func read(account: String) -> String?
    func write(_ value: String, account: String)
    func delete(account: String)
}

/// HostKeychain 的实例化外壳，让 HostStore 能以协议持有它
struct KeychainSecretStore: HostSecretStoring {
    func read(account: String) -> String? { HostKeychain.read(account: account) }
    func write(_ value: String, account: String) { HostKeychain.write(value, account: account) }
    func delete(account: String) { HostKeychain.delete(account: account) }
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

    /// 非敏感字段的落点。生产恒为 .standard；测试/UI 夹具注入独立 suite 免污染
    private let defaults: UserDefaults
    /// 敏感字段的落点。生产恒为 Keychain；单测按可用性注入（见 HostSecretStoring）
    private let secrets: any HostSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secrets: any HostSecretStoring = KeychainSecretStore()
    ) {
        self.defaults = defaults
        self.secrets = secrets
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
        let legacyHost = defaults.string(forKey: Keys.legacyHost) ?? ""
        let legacyToken = secrets.read(account: HostKeychain.legacyAccount) ?? ""
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
        secrets.write(legacyToken, account: config.id.uuidString)
        secrets.delete(account: HostKeychain.legacyAccount)
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
        secrets.write(token, account: config.id.uuidString)
        if activeHostID == nil { activeHostID = config.id }
        persist()
        return config
    }

    /// 扫码配对成功后入库。同一台 Mac 重复扫码不追加新行：原地刷新名称、地址与公钥，
    /// 避免设置页出现两行指向同一台机器、各持一份信任记录。
    @discardableResult
    func addPaired(
        macDeviceId: String, macIdentityPublicKey: String, name: String,
        lanHost: String?, lanPort: Int?, relay: String?
    ) -> BridgeHostConfig {
        if let index = hosts.firstIndex(where: { $0.macDeviceId == macDeviceId }) {
            hosts[index].name = name
            hosts[index].lanHost = lanHost
            hosts[index].lanPort = lanPort
            hosts[index].relay = relay
            secrets.write(
                macIdentityPublicKey, account: Self.macIdentityAccount(hosts[index].id)
            )
            persist()
            return hosts[index]
        }
        var config = BridgeHostConfig(
            id: UUID(), name: name, host: "", port: 0, lastConnectedAt: nil
        )
        config.macDeviceId = macDeviceId
        config.lanHost = lanHost
        config.lanPort = lanPort
        config.relay = relay
        hosts.append(config)
        secrets.write(macIdentityPublicKey, account: Self.macIdentityAccount(config.id))
        if activeHostID == nil { activeHostID = config.id }
        persist()
        return config
    }

    /// paired 主机的 mac 身份公钥（trusted_reconnect 的信任根）
    func macIdentityPublicKey(for id: UUID) -> String? {
        secrets.read(account: Self.macIdentityAccount(id))
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        secrets.delete(account: id.uuidString)
        secrets.delete(account: Self.macIdentityAccount(id))
        if activeHostID == id { activeHostID = hosts.first?.id }
        persist()
    }

    private static func macIdentityAccount(_ id: UUID) -> String {
        "mac-identity-\(id.uuidString)"
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
        secrets.read(account: id.uuidString) ?? ""
    }

    func setToken(_ token: String, for id: UUID) {
        secrets.write(token, account: id.uuidString)
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

/// 手机侧配对身份：Ed25519 种子 + 稳定设备 id，首次用到时生成后进 Keychain
/// （仅本机、解锁可读），此后重装前不再变化——mac 端的信任表按它们记账，
/// 每次都换的话 trusted_reconnect 永远对不上。全 App 经 shared 取，单例语义。
struct PhonePairingIdentity: Sendable {
    static let shared = PhonePairingIdentity()

    let identity: PhoneIdentity
    let deviceId: String

    private init() {
        if let seedBase64 = HostKeychain.read(account: Accounts.seed),
           let restored = try? PhoneIdentity(seedBase64: seedBase64) {
            identity = restored
        } else {
            // 首次使用或 Keychain 记录损坏：重新生成（后者会让 mac 端信任失效，
            // 表现为 phone_identity_changed，用户重新扫码即可恢复）
            let fresh = PhoneIdentity()
            HostKeychain.write(fresh.seedBase64, account: Accounts.seed)
            identity = fresh
        }
        if let stored = HostKeychain.read(account: Accounts.deviceId), !stored.isEmpty {
            deviceId = stored
        } else {
            let fresh = UUID().uuidString
            HostKeychain.write(fresh, account: Accounts.deviceId)
            deviceId = fresh
        }
    }

    private enum Accounts {
        static let seed = "phone-identity-seed"
        static let deviceId = "phone-device-id"
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
