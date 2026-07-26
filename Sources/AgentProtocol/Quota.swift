// AgentProtocol —— bridge/src/protocol/events.ts 账号额度部分的 Swift 同构镜像。
import Foundation

/// 一个滚动额度窗口。显示名必须由 windowDurationMins 推导（5h/周/…），
/// 不能按 primary/secondary 位置硬编码——实测有账号只有一个 10080 分钟的
/// primary 窗口而没有 secondary。
public struct QuotaWindow: Sendable, Equatable, Codable, Identifiable {
    /// 跨快照稳定的窗口标识：`<limitId>/primary` 或 `<limitId>/secondary`
    public var id: String
    /// 运行时给的人读名（模型专属桶才有）；nil 时客户端按窗口时长推导显示名
    public var label: String?
    /// wire 原值不钳位，显示层自行 clamp 到 0–100
    public var usedPercent: Int
    public var windowDurationMins: Int?
    /// unix 秒
    public var resetsAt: Int64?

    public init(
        id: String, label: String?, usedPercent: Int,
        windowDurationMins: Int?, resetsAt: Int64?
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    // TS 侧是 `| null` 而非可选属性，键必须始终存在，用 encode 而不是 encodeIfPresent
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(windowDurationMins, forKey: .windowDurationMins)
        try container.encode(resetsAt, forKey: .resetsAt)
    }
}

/// 账号级额度快照。目前只有 codex 有程序化通道，agent 恒为 .codex，
/// 但契约不为单一实现收窄类型。
public struct AgentQuotaSnapshot: Sendable, Equatable, Codable {
    public var agent: AgentKind
    public var planType: String?
    public var windows: [QuotaWindow]
    /// bridge 收到该快照的时刻；客户端据此显示数据新鲜度
    public var capturedAtMs: Int64

    public init(
        agent: AgentKind, planType: String?, windows: [QuotaWindow], capturedAtMs: Int64
    ) {
        self.agent = agent
        self.planType = planType
        self.windows = windows
        self.capturedAtMs = capturedAtMs
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        try container.encode(planType, forKey: .planType)
        try container.encode(windows, forKey: .windows)
        try container.encode(capturedAtMs, forKey: .capturedAtMs)
    }
}
