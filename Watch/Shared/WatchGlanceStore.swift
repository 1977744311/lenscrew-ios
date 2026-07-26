// 小组件与表盘复杂功能的数据交接（手表 App ↔ widget 扩展共源，纯 Foundation）。
// 手表 App 每次收到快照就把腕上要显示的数字写进 app group defaults 并请求刷新；
// widget 进程只读。app group 生效需要签名带 entitlements，拿不到共享容器时
// 小组件退化为占位数字，不 crash。
import Foundation

enum WatchGlanceStore {
    static let appGroup = "group.dev.steven.LensCrew"
    /// 主视图一瞥小组件的 kind；表盘复杂功能各模块的 kind 见 WatchWidget
    static let widgetKind = "LensCrewWatchGlance"
    // v2：新增额度与主机数。换键即弃读旧数据，App 收到下一份快照就会重写
    private static let key = "glance.v2"

    /// 一行额度：一个滚动窗口的剩余百分比（主窗口排最前，最多存 3 行）
    struct QuotaGlance: Codable, Sendable, Equatable {
        var hostName: String
        /// 运行时给的窗口名（模型专属桶才有）；nil 时渲染层按时长推导
        var label: String?
        var remainingPercent: Int
        var windowDurationMins: Int?
        /// unix 秒
        var resetsAt: Int64?
    }

    /// 一瞥数据：待审批数、运行中数、最紧急一条审批的单行摘要 + 额度与主机数
    struct Glance: Codable, Sendable, Equatable {
        var pendingApprovals: Int
        var running: Int
        var headline: String?
        var connectedHosts: Int = 0
        var quota: [QuotaGlance] = []
        /// 额度采集时刻（ms）；渲染层据此显示新鲜度
        var quotaCapturedAtMs: Int64?
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

    /// windowDurationMins → 人读窗口名：300 → "5h"、10080 → "周"、43200 → "月"。
    /// 表盘上没地方放长文案，能一到两个字就一到两个字
    static func windowName(mins: Int?) -> String? {
        guard let mins, mins > 0 else { return nil }
        if mins % 43200 == 0 { return mins == 43200 ? "月" : "\(mins / 43200)月" }
        if mins % 10080 == 0 { return mins == 10080 ? "周" : "\(mins / 10080)周" }
        if mins % 1440 == 0 { return mins == 1440 ? "日" : "\(mins / 1440)天" }
        if mins % 60 == 0 { return "\(mins / 60)h" }
        return "\(mins)m"
    }
}
