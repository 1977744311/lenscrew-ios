import Foundation
import Testing

@testable import LensCrew

/// HostSecretStoring 的进程内实现，契约与 Keychain 版一致：写空串等价删除
private final class InMemorySecretStore: HostSecretStoring {
    private var values: [String: String] = [:]

    func read(account: String) -> String? { values[account] }

    func write(_ value: String, account: String) {
        values[account] = value.isEmpty ? nil : value
    }

    func delete(account: String) { values[account] = nil }
}

/// 优先真 Keychain：探测一次读写回环，可用就用生产实现（模拟器 keychain）。
/// 无签名构建（xcodebuild … CODE_SIGNING_ALLOWED=NO）下 SecItem* 因缺
/// entitlement 全线失败，此时退化为进程内字典——两条路径跑完全相同的断言。
private func makeSecretStore() -> any HostSecretStoring {
    let keychain = KeychainSecretStore()
    let probeAccount = "hoststore-tests-probe"
    keychain.write("probe", account: probeAccount)
    defer { keychain.delete(account: probeAccount) }
    return keychain.read(account: probeAccount) == "probe" ? keychain : InMemorySecretStore()
}

/// 每个用例独立 suite；用完整域清空，绝不落到 standard
private struct SuiteBox {
    let name: String
    let defaults: UserDefaults

    init() {
        name = "hoststore-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: name)
    }
}

/// 旧版单主机口令的 Keychain account 名（HostStore 内部常量的镜像）
private let legacyAccount = "token"

// 真 keychain 可用时 legacy account 是共享全局名，串行跑避免用例互踩
@Suite("HostStore", .serialized)
@MainActor
struct HostStoreTests {

    @Test("旧单主机配置一次性迁移成 paired=false 的「我的 Mac」并设 active")
    func migratesLegacySingleHost() throws {
        let box = SuiteBox()
        defer { box.tearDown() }
        let secrets = makeSecretStore()
        box.defaults.set("192.168.1.20", forKey: "bridge.host")
        box.defaults.set(4400, forKey: "bridge.port")
        secrets.write("legacy-token", account: legacyAccount)
        defer { secrets.delete(account: legacyAccount) }

        let store = HostStore(defaults: box.defaults, secrets: secrets)
        defer { for host in store.hosts { store.remove(host.id) } }

        #expect(store.hosts.count == 1)
        let host = try #require(store.hosts.first)
        #expect(host.name == "我的 Mac")
        #expect(host.host == "192.168.1.20")
        #expect(host.port == 4400)
        #expect(!host.isPaired)
        #expect(store.activeHostID == host.id)
        #expect(store.token(for: host.id) == "legacy-token")
        // 旧键随迁清掉：defaults 两键删除、口令搬进按主机 UUID 的记录
        #expect(box.defaults.string(forKey: "bridge.host") == nil)
        #expect(box.defaults.object(forKey: "bridge.port") == nil)
        #expect(secrets.read(account: legacyAccount) == nil)
    }

    @Test("迁移幂等：bridge.hosts.v1 已存在时旧键再现也不再建第二条")
    func migrationRunsOnlyOnce() throws {
        let box = SuiteBox()
        defer { box.tearDown() }
        let secrets = makeSecretStore()
        box.defaults.set("192.168.1.20", forKey: "bridge.host")
        secrets.write("legacy-token", account: legacyAccount)
        defer { secrets.delete(account: legacyAccount) }

        let first = HostStore(defaults: box.defaults, secrets: secrets)
        let migratedID = try #require(first.hosts.first?.id)
        defer { first.remove(migratedID) }

        // 伪造旧键复活：迁移只认 hosts.v1 是否存在，不该再跑一遍
        box.defaults.set("10.0.0.9", forKey: "bridge.host")
        secrets.write("stale", account: legacyAccount)

        let second = HostStore(defaults: box.defaults, secrets: secrets)
        #expect(second.hosts.count == 1)
        #expect(second.hosts.first?.id == migratedID)
        #expect(second.hosts.first?.host == "192.168.1.20")
        #expect(second.token(for: migratedID) == "legacy-token", "口令仍是首轮迁移的那份")
    }

    @Test("没有旧配置时不迁移：空列表、无 active")
    func skipsMigrationWithoutLegacyData() {
        let box = SuiteBox()
        defer { box.tearDown() }

        let store = HostStore(defaults: box.defaults, secrets: makeSecretStore())
        #expect(store.hosts.isEmpty)
        #expect(store.activeHostID == nil)
        #expect(store.active == nil)
    }

    @Test("addPaired 同 macDeviceId 原地刷新，不追加第二行")
    func addPairedRefreshesInPlace() throws {
        let box = SuiteBox()
        defer { box.tearDown() }
        let store = HostStore(defaults: box.defaults, secrets: makeSecretStore())
        defer { for host in store.hosts { store.remove(host.id) } }

        let created = store.addPaired(
            macDeviceId: "mac-1", macIdentityPublicKey: "pk-A", name: "书房 Mac",
            lanHost: "10.0.0.2", lanPort: 4311, relay: nil
        )
        #expect(store.hosts.count == 1)
        #expect(created.isPaired)
        #expect(store.activeHostID == created.id)
        #expect(store.macIdentityPublicKey(for: created.id) == "pk-A")

        let refreshed = store.addPaired(
            macDeviceId: "mac-1", macIdentityPublicKey: "pk-B", name: "书房 Mac Studio",
            lanHost: "10.0.0.3", lanPort: 4312, relay: "https://relay.example"
        )
        #expect(store.hosts.count == 1)
        #expect(refreshed.id == created.id)
        let host = try #require(store.hosts.first)
        #expect(host.name == "书房 Mac Studio")
        #expect(host.lanHost == "10.0.0.3")
        #expect(host.lanPort == 4312)
        #expect(host.relay == "https://relay.example")
        #expect(store.macIdentityPublicKey(for: created.id) == "pk-B")

        // 不同 macDeviceId 才是第二台
        store.addPaired(
            macDeviceId: "mac-2", macIdentityPublicKey: "pk-C", name: "客厅 Mac",
            lanHost: nil, lanPort: nil, relay: "https://relay.example"
        )
        #expect(store.hosts.count == 2)
    }

    @Test("口令按主机各存各的，改写与清空互不串台")
    func tokenRoundTripPerHost() {
        let box = SuiteBox()
        defer { box.tearDown() }
        let store = HostStore(defaults: box.defaults, secrets: makeSecretStore())
        defer { for host in store.hosts { store.remove(host.id) } }

        let a = store.add(name: "A", host: "h1", port: 4311, token: "tok-a")
        let b = store.add(name: "B", host: "h2", port: 4312, token: "tok-b")
        #expect(store.token(for: a.id) == "tok-a")
        #expect(store.token(for: b.id) == "tok-b")

        store.setToken("tok-a2", for: a.id)
        #expect(store.token(for: a.id) == "tok-a2")
        #expect(store.token(for: b.id) == "tok-b")

        // 空口令即删除记录，读回空串而不是残影
        store.setToken("", for: b.id)
        #expect(store.token(for: b.id) == "")
    }

    @Test("remove 掉 active 主机回落第一台；setActive 无视未知 id")
    func removeAndSetActive() throws {
        let box = SuiteBox()
        defer { box.tearDown() }
        let secrets = makeSecretStore()
        let store = HostStore(defaults: box.defaults, secrets: secrets)
        defer { for host in store.hosts { store.remove(host.id) } }

        let a = store.add(name: "A", host: "h1", port: 4311, token: "")
        let b = store.add(name: "B", host: "h2", port: 4312, token: "")
        #expect(store.activeHostID == a.id, "第一台入库即 active")

        store.setActive(b.id)
        #expect(store.activeHostID == b.id)
        // active 选择要持久化：同 suite 重建后读回同一台
        let reloaded = HostStore(defaults: box.defaults, secrets: secrets)
        #expect(reloaded.activeHostID == b.id)

        store.setActive(UUID())
        #expect(store.activeHostID == b.id, "未知 id 不改变 active")

        store.remove(b.id)
        #expect(store.activeHostID == a.id, "删掉 active 回落到第一台")
        #expect(store.token(for: b.id) == "", "删除同时清掉口令记录")

        store.remove(a.id)
        #expect(store.hosts.isEmpty)
        #expect(store.activeHostID == nil)
    }

    @Test("工作目录 MRU：去重置顶、修剪空白、上限 8 条、可持久化读回")
    func workspaceRootsMRU() {
        let box = SuiteBox()
        defer { box.tearDown() }
        let secrets = makeSecretStore()
        let store = HostStore(defaults: box.defaults, secrets: secrets)

        store.remember(root: "  /Users/me/proj  ")
        #expect(store.workspaceRoots == ["/Users/me/proj"])

        store.remember(root: "   ")
        #expect(store.workspaceRoots == ["/Users/me/proj"], "空白路径不入列")

        store.remember(root: "/b")
        store.remember(root: "/Users/me/proj")
        #expect(store.workspaceRoots == ["/Users/me/proj", "/b"], "重复项置顶不重复建")

        for index in 0..<10 {
            store.remember(root: "/r\(index)")
        }
        #expect(store.workspaceRoots.count == 8, "MRU 封顶 8 条")
        #expect(store.workspaceRoots.first == "/r9")

        let reloaded = HostStore(defaults: box.defaults, secrets: secrets)
        #expect(reloaded.workspaceRoots == store.workspaceRoots)
    }
}
