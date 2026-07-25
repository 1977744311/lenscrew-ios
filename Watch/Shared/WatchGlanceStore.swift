// Smart Stack 小组件的数据交接（手表 App ↔ widget 扩展共源，纯 Foundation）。
// 手表 App 每次收到快照就把小组件要的三个数写进 app group defaults 并请求刷新；
// widget 进程只读。app group 生效需要签名带 entitlements，拿不到共享容器时
// 小组件退化为占位数字，不 crash。
import Foundation

enum WatchGlanceStore {
    static let appGroup = "group.dev.steven.LensCrew"
    static let widgetKind = "LensCrewWatchGlance"
    private static let key = "glance.v1"

    /// 一瞥数据：待审批数、运行中数、最紧急一条审批的单行摘要
    struct Glance: Codable, Sendable, Equatable {
        var pendingApprovals: Int
        var running: Int
        var headline: String?
    }

    static func save(_ glance: Glance) {
        guard let defaults = UserDefaults(suiteName: appGroup),
            let data = try? JSONEncoder().encode(glance)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> Glance? {
        guard let defaults = UserDefaults(suiteName: appGroup),
            let data = defaults.data(forKey: key)
        else { return nil }
        return try? JSONDecoder().decode(Glance.self, from: data)
    }
}
