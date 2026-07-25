import Foundation

public enum SessionMode: String, Sendable, Codable {
    case `default`, plan
}

/// 客户端 → bridge 的指令。手机和眼镜发的是同一套指令，
/// 区别只在眼镜受 tap-only 输入限制，发不出 sendMessage 这类需要文本的指令。
public enum ClientCommand: Sendable, Equatable {
    case listSessions
    case createSession(
        agent: AgentKind, workspaceRoot: String, model: String?, mode: SessionMode
    )
    case resumeSession(agent: AgentKind, nativeID: String, workspaceRoot: String)
    case sendMessage(sessionID: String, text: String)
    case interrupt(sessionID: String)
    case resolveApproval(sessionID: String, approvalID: String, optionID: String)
    case closeSession(sessionID: String)
    case subscribe(sessionID: String, fromSeq: Int)
}

extension ClientCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, agent, workspaceRoot, model, mode, nativeId
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
                mode: try container.decode(SessionMode.self, forKey: .mode)
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
        case let .createSession(agent, workspaceRoot, model, mode):
            try container.encode("createSession", forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encode(workspaceRoot, forKey: .workspaceRoot)
            try container.encode(model, forKey: .model)
            try container.encode(mode, forKey: .mode)
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
