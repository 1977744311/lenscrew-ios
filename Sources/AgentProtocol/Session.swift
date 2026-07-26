// AgentProtocol —— bridge/src/protocol/events.ts 的 Swift 同构镜像。
// 两侧共用 protocol/fixtures/*.json 做往返测试；改了一侧而不同步，两侧测试都会红。
// 线上格式的判定权在 TypeScript 那份（bridge 直接面对三个运行时的原生协议），
// 本文件负责忠实还原，不得自行加字段或改语义。
import Foundation

public enum AgentKind: String, Sendable, Codable, CaseIterable {
    case codex, claude, cursor
}

/// adapter 自陈的能力。客户端据此决定 UI，而不是按 agent 种类硬编码——
/// 同一个 agent 换驱动方式能力就会变（cursor 走 acp 有审批、走 -p 没有）。
public struct AgentCapabilities: Sendable, Equatable, Codable {
    public var approvals: Bool
    public var steering: Bool
    public var interrupt: Bool
    public var planMode: Bool
    public var resume: Bool
    public var streamingDeltas: Bool

    public init(
        approvals: Bool, steering: Bool, interrupt: Bool,
        planMode: Bool, resume: Bool, streamingDeltas: Bool
    ) {
        self.approvals = approvals
        self.steering = steering
        self.interrupt = interrupt
        self.planMode = planMode
        self.resume = resume
        self.streamingDeltas = streamingDeltas
    }
}

public enum SessionStatus: String, Sendable, Codable {
    case starting, idle, running, awaitingApproval, error, ended
}

/// 会话模式的一个档位。id 属于各 adapter 自己的命名空间
/// （codex: plan/default/auto/full，claude: plan/default/acceptEdits/bypass，
/// cursor: agent/plan/ask），客户端只展示、不解释。
public struct SessionModeOption: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var label: String
    /// 一句话说明这一档批什么、放什么（选择器副文本）
    public var detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct AgentSession: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var agent: AgentKind
    /// 运行时自己的会话 id（codex threadId / claude session_id / acp sessionId），用于续接
    public var nativeId: String?
    public var workspaceRoot: String
    public var title: String
    public var model: String?
    public var status: SessionStatus
    public var capabilities: AgentCapabilities
    /// 当前审批/协作模式；运行时没有模式概念时为 nil
    public var modeId: String?
    /// 本会话可切换的模式清单；空数组表示不支持切换
    public var modes: [SessionModeOption]
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    public init(
        id: String, agent: AgentKind, nativeId: String?, workspaceRoot: String,
        title: String, model: String?, status: SessionStatus,
        capabilities: AgentCapabilities, modeId: String?, modes: [SessionModeOption],
        createdAtMs: Int64, updatedAtMs: Int64
    ) {
        self.id = id
        self.agent = agent
        self.nativeId = nativeId
        self.workspaceRoot = workspaceRoot
        self.title = title
        self.model = model
        self.status = status
        self.capabilities = capabilities
        self.modeId = modeId
        self.modes = modes
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    // TS 侧声明的是 `string | null` 而非可选属性，键必须始终存在，
    // 因此这里用 encode 而不是 encodeIfPresent。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agent, forKey: .agent)
        try container.encode(nativeId, forKey: .nativeId)
        try container.encode(workspaceRoot, forKey: .workspaceRoot)
        try container.encode(title, forKey: .title)
        try container.encode(model, forKey: .model)
        try container.encode(status, forKey: .status)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(modeId, forKey: .modeId)
        try container.encode(modes, forKey: .modes)
        try container.encode(createdAtMs, forKey: .createdAtMs)
        try container.encode(updatedAtMs, forKey: .updatedAtMs)
    }
}
