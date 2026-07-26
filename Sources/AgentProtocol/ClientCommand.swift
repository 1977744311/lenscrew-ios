import Foundation

/// 客户端 → bridge 的指令。手机和眼镜发的是同一套指令，
/// 区别只在眼镜受 tap-only 输入限制，发不出 sendMessage 这类需要文本的指令。
public enum ClientCommand: Sendable, Equatable {
    case listSessions
    /// modeID 见 SessionModeOption.id；nil 用 adapter 的缺省档
    case createSession(
        agent: AgentKind, workspaceRoot: String, model: String?, modeID: String?
    )
    case resumeSession(agent: AgentKind, nativeID: String, workspaceRoot: String)
    case sendMessage(sessionID: String, text: String)
    case interrupt(sessionID: String)
    case resolveApproval(sessionID: String, approvalID: String, optionID: String)
    /// 会话中切换模式；codex 下一轮 turn 生效，claude/cursor 即时生效
    case setSessionMode(sessionID: String, modeID: String)
    /// 会话中切换模型；codex 下一轮 turn 生效，claude/cursor 即时生效
    case setSessionModel(sessionID: String, modelID: String)
    case closeSession(sessionID: String)
    case subscribe(sessionID: String, fromSeq: Int)
}

extension ClientCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, agent, workspaceRoot, model, modeId, modelId, nativeId
        case sessionId, text, approvalId, optionId, fromSeq
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "listSessions":
            self = .listSessions
        case "createSession":
            self = .createSession(
                agent: try container.decode(AgentKind.self, forKey: .agent),
                workspaceRoot: try container.decode(String.self, forKey: .workspaceRoot),
                model: try container.decodeIfPresent(String.self, forKey: .model),
                modeID: try container.decodeIfPresent(String.self, forKey: .modeId)
            )
        case "resumeSession":
            self = .resumeSession(
                agent: try container.decode(AgentKind.self, forKey: .agent),
                nativeID: try container.decode(String.self, forKey: .nativeId),
                workspaceRoot: try container.decode(String.self, forKey: .workspaceRoot)
            )
        case "sendMessage":
            self = .sendMessage(
                sessionID: try container.decode(String.self, forKey: .sessionId),
                text: try container.decode(String.self, forKey: .text)
            )
        case "interrupt":
            self = .interrupt(
                sessionID: try container.decode(String.self, forKey: .sessionId)
            )
        case "resolveApproval":
            self = .resolveApproval(
                sessionID: try container.decode(String.self, forKey: .sessionId),
                approvalID: try container.decode(String.self, forKey: .approvalId),
                optionID: try container.decode(String.self, forKey: .optionId)
            )
        case "setSessionMode":
            self = .setSessionMode(
                sessionID: try container.decode(String.self, forKey: .sessionId),
                modeID: try container.decode(String.self, forKey: .modeId)
            )
        case "setSessionModel":
            self = .setSessionModel(
                sessionID: try container.decode(String.self, forKey: .sessionId),
                modelID: try container.decode(String.self, forKey: .modelId)
            )
        case "closeSession":
            self = .closeSession(
                sessionID: try container.decode(String.self, forKey: .sessionId)
            )
        case "subscribe":
            self = .subscribe(
                sessionID: try container.decode(String.self, forKey: .sessionId),
                fromSeq: try container.decode(Int.self, forKey: .fromSeq)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 ClientCommand type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listSessions:
            try container.encode("listSessions", forKey: .type)
        case let .createSession(agent, workspaceRoot, model, modeID):
            try container.encode("createSession", forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encode(workspaceRoot, forKey: .workspaceRoot)
            try container.encode(model, forKey: .model)
            try container.encode(modeID, forKey: .modeId)
        case let .resumeSession(agent, nativeID, workspaceRoot):
            try container.encode("resumeSession", forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encode(nativeID, forKey: .nativeId)
            try container.encode(workspaceRoot, forKey: .workspaceRoot)
        case let .sendMessage(sessionID, text):
            try container.encode("sendMessage", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(text, forKey: .text)
        case let .interrupt(sessionID):
            try container.encode("interrupt", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
        case let .resolveApproval(sessionID, approvalID, optionID):
            try container.encode("resolveApproval", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(approvalID, forKey: .approvalId)
            try container.encode(optionID, forKey: .optionId)
        case let .setSessionMode(sessionID, modeID):
            try container.encode("setSessionMode", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(modeID, forKey: .modeId)
        case let .setSessionModel(sessionID, modelID):
            try container.encode("setSessionModel", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(modelID, forKey: .modelId)
        case let .closeSession(sessionID):
            try container.encode("closeSession", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
        case let .subscribe(sessionID, fromSeq):
            try container.encode("subscribe", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(fromSeq, forKey: .fromSeq)
        }
    }
}
