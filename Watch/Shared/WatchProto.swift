// Watch ↔ iPhone 的 WatchConnectivity 载荷契约。本文件同时编进 iOS 与 watchOS
// 两个 target（project.yml 里 iOS sources 单独挂了这一个文件），两端共用同一份
// Codable 定义，不另造线上格式：审批本体直接复用 AgentProtocol.ApprovalRequest。
// 手表不引 BridgeLink、不持密钥，这里只允许出现可以直接渲染的公开字段。
import AgentProtocol
import Foundation

/// 会话流水在手表上的单行摘要。iPhone 侧用 blockPreview 预渲染成人话，
/// 手表不解 TranscriptBlock——省掉一份折叠逻辑，也把体积压到最小。
struct WatchTranscriptLine: Codable, Sendable, Equatable {
    var text: String
    var mono: Bool
}

/// 一条待审批：渲染 W1 审批卡所需的最小字段
struct WatchApprovalDTO: Codable, Sendable, Equatable, Identifiable {
    var hostID: UUID
    var hostName: String
    var sessionID: String
    var sessionTitle: String
    var agent: AgentKind
    var approval: ApprovalRequest

    /// approval.id 可能跨主机撞号，复合 id 与手机侧 PendingApprovalItem 同构
    var id: String { "\(hostID.uuidString)#\(approval.id)" }
}

/// 一条会话行：W2 列表与 W3 详情共用
struct WatchSessionDTO: Codable, Sendable, Equatable, Identifiable {
    var hostID: UUID
    var hostName: String
    var sessionID: String
    var title: String
    var agent: AgentKind
    var status: SessionStatus
    var updatedAtMs: Int64
    /// 最近 2–3 个块的单行摘要（时间正序）
    var recentLines: [WatchTranscriptLine]

    var id: String { "\(hostID.uuidString)#\(sessionID)" }
}

/// 一台主机上一个 agent 的账号额度：表盘复杂功能与小组件用。
/// windows 直接复用 AgentProtocol.QuotaWindow，显示名由 windowDurationMins 推导
struct WatchQuotaDTO: Codable, Sendable, Equatable, Identifiable {
    var hostID: UUID
    var hostName: String
    var agent: AgentKind
    var planType: String?
    var windows: [QuotaWindow]
    var capturedAtMs: Int64

    var id: String { "\(hostID.uuidString)#\(agent.rawValue)" }
}

/// 推给手表的一瞥快照。applicationContext 语义：只有最新一份有意义。
struct WatchSnapshot: Codable, Sendable, Equatable {
    var approvals: [WatchApprovalDTO]
    var sessions: [WatchSessionDTO]
    var quotas: [WatchQuotaDTO]
    var connectedHosts: Int

    static let empty = WatchSnapshot(
        approvals: [], sessions: [], quotas: [], connectedHosts: 0
    )

    init(
        approvals: [WatchApprovalDTO], sessions: [WatchSessionDTO],
        quotas: [WatchQuotaDTO], connectedHosts: Int
    ) {
        self.approvals = approvals
        self.sessions = sessions
        self.quotas = quotas
        self.connectedHosts = connectedHosts
    }

    /// applicationContext 可能还压着升级前的旧快照，新字段缺席按空值兜底
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try container.decode([WatchApprovalDTO].self, forKey: .approvals)
        sessions = try container.decode([WatchSessionDTO].self, forKey: .sessions)
        quotas = try container.decodeIfPresent([WatchQuotaDTO].self, forKey: .quotas) ?? []
        connectedHosts = try container.decodeIfPresent(Int.self, forKey: .connectedHosts) ?? 0
    }

    /// 多台 Mac 并存时，行上才带主机名
    var multiHost: Bool {
        var hosts = Set(sessions.map(\.hostID))
        hosts.formUnion(approvals.map(\.hostID))
        return hosts.count > 1
    }
}

/// 手表回传的动作，三种都按 (hostID, sessionID) 由 iPhone 路由到对应主机
enum WatchAction: Codable, Sendable, Equatable {
    case resolve(hostID: UUID, sessionID: String, approvalID: String, optionID: String)
    case sendText(hostID: UUID, sessionID: String, text: String)
    case interrupt(hostID: UUID, sessionID: String)
}

/// 载荷编解码与体积上限。WCSession 的各通道都是 plist 字典，统一用
/// 单键 + JSON Data 承载，键名即通道语义；纯函数，便于将来单测。
enum WatchWire {
    static let snapshotKey = "snapshot"
    static let actionKey = "action"

    // applicationContext 有体积预算（数十 KB 级），超出的部分腕上也读不过来
    static let maxApprovals = 8
    static let maxSessions = 12
    static let maxRecentLines = 3
    static let maxDetailChars = 800
    static let maxLineChars = 120
    /// 额度条目（每台主机每个 agent 一条）与单条内窗口数的上限
    static let maxQuotaEntries = 4
    static let maxQuotaWindows = 4

    static func encode(_ snapshot: WatchSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    static func decodeSnapshot(_ data: Data) -> WatchSnapshot? {
        try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    static func encode(_ action: WatchAction) throws -> Data {
        try JSONEncoder().encode(action)
    }

    static func decodeAction(_ data: Data) -> WatchAction? {
        try? JSONDecoder().decode(WatchAction.self, from: data)
    }

    /// 按字符数截断并补省略号；上限之内原样返回
    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "…"
    }
}
