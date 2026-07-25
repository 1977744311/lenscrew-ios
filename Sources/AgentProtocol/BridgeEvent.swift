import Foundation

/// bridge → 客户端的事件。每条带会话内单调递增的 seq：
/// 手机和眼镜都可能随时断线，重连时用 `.subscribe(fromSeq:)` 补齐，而不是重拉整个会话。
public enum BridgeEvent: Sendable, Equatable {
    case sessionCreated(seq: Int, session: AgentSession)
    case sessionStatus(seq: Int, sessionID: String, status: SessionStatus)
    case sessionClosed(seq: Int, sessionID: String, reason: String)
    case blockAppended(seq: Int, sessionID: String, block: TranscriptBlock)
    case blockUpdated(
        seq: Int, sessionID: String, blockID: String, patch: TranscriptBlockPatch
    )
    case approvalRequested(seq: Int, sessionID: String, approval: ApprovalRequest)
    case approvalSettled(
        seq: Int, sessionID: String, approvalID: String,
        optionID: String?, outcome: ApprovalOutcome
    )
    case turnCompleted(
        seq: Int, sessionID: String, inputTokens: Int?, outputTokens: Int?
    )
    case bridgeError(seq: Int, sessionID: String?, message: String, fatal: Bool)

    public var seq: Int {
        switch self {
        case let .sessionCreated(seq, _): return seq
        case let .sessionStatus(seq, _, _): return seq
        case let .sessionClosed(seq, _, _): return seq
        case let .blockAppended(seq, _, _): return seq
        case let .blockUpdated(seq, _, _, _): return seq
        case let .approvalRequested(seq, _, _): return seq
        case let .approvalSettled(seq, _, _, _, _): return seq
        case let .turnCompleted(seq, _, _, _): return seq
        case let .bridgeError(seq, _, _, _): return seq
        }
    }

    /// 非会话级事件（致命的 bridgeError）返回 nil
    public var sessionID: String? {
        switch self {
        case let .sessionCreated(_, session): return session.id
        case let .sessionStatus(_, id, _): return id
        case let .sessionClosed(_, id, _): return id
        case let .blockAppended(_, id, _): return id
        case let .blockUpdated(_, id, _, _): return id
        case let .approvalRequested(_, id, _): return id
        case let .approvalSettled(_, id, _, _, _): return id
        case let .turnCompleted(_, id, _, _): return id
        case let .bridgeError(_, id, _, _): return id
        }
    }
}

extension BridgeEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, seq, sessionId, session, status, reason, block, blockId, patch
        case approval, approvalId, optionId, outcome
        case inputTokens, outputTokens, message, fatal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let seq = try container.decode(Int.self, forKey: .seq)
        switch type {
        case "sessionCreated":
            self = .sessionCreated(
                seq: seq, session: try container.decode(AgentSession.self, forKey: .session)
            )
        case "sessionStatus":
            self = .sessionStatus(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                status: try container.decode(SessionStatus.self, forKey: .status)
            )
        case "sessionClosed":
            self = .sessionClosed(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "blockAppended":
            self = .blockAppended(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                block: try container.decode(TranscriptBlock.self, forKey: .block)
            )
        case "blockUpdated":
            self = .blockUpdated(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                blockID: try container.decode(String.self, forKey: .blockId),
                patch: try container.decode(TranscriptBlockPatch.self, forKey: .patch)
            )
        case "approvalRequested":
            self = .approvalRequested(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                approval: try container.decode(ApprovalRequest.self, forKey: .approval)
            )
        case "approvalSettled":
            self = .approvalSettled(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                approvalID: try container.decode(String.self, forKey: .approvalId),
                optionID: try container.decodeIfPresent(String.self, forKey: .optionId),
                outcome: try container.decode(ApprovalOutcome.self, forKey: .outcome)
            )
        case "turnCompleted":
            self = .turnCompleted(
                seq: seq,
                sessionID: try container.decode(String.self, forKey: .sessionId),
                inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
                outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            )
        case "bridgeError":
            self = .bridgeError(
                seq: seq,
                sessionID: try container.decodeIfPresent(String.self, forKey: .sessionId),
                message: try container.decode(String.self, forKey: .message),
                fatal: try container.decode(Bool.self, forKey: .fatal)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 BridgeEvent type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        switch self {
        case let .sessionCreated(_, session):
            try container.encode("sessionCreated", forKey: .type)
            try container.encode(session, forKey: .session)
        case let .sessionStatus(_, sessionID, status):
            try container.encode("sessionStatus", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(status, forKey: .status)
        case let .sessionClosed(_, sessionID, reason):
            try container.encode("sessionClosed", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(reason, forKey: .reason)
        case let .blockAppended(_, sessionID, block):
            try container.encode("blockAppended", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(block, forKey: .block)
        case let .blockUpdated(_, sessionID, blockID, patch):
            try container.encode("blockUpdated", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(blockID, forKey: .blockId)
            try container.encode(patch, forKey: .patch)
        case let .approvalRequested(_, sessionID, approval):
            try container.encode("approvalRequested", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(approval, forKey: .approval)
        case let .approvalSettled(_, sessionID, approvalID, optionID, outcome):
            try container.encode("approvalSettled", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(approvalID, forKey: .approvalId)
            try container.encode(optionID, forKey: .optionId)
            try container.encode(outcome, forKey: .outcome)
        case let .turnCompleted(_, sessionID, inputTokens, outputTokens):
            try container.encode("turnCompleted", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(inputTokens, forKey: .inputTokens)
            try container.encode(outputTokens, forKey: .outputTokens)
        case let .bridgeError(_, sessionID, message, fatal):
            try container.encode("bridgeError", forKey: .type)
            try container.encode(sessionID, forKey: .sessionId)
            try container.encode(message, forKey: .message)
            try container.encode(fatal, forKey: .fatal)
        }
    }
}
