import AgentProtocol
import Foundation

public struct SessionState: Sendable, Equatable {
    public var session: AgentSession
    public var blocks: [TranscriptBlock]
    public var pendingApprovals: [ApprovalRequest]
    /// 已消费到的最大 seq，重连时据此续订
    public var lastSeq: Int

    public init(session: AgentSession) {
        self.session = session
        self.blocks = []
        self.pendingApprovals = []
        self.lastSeq = 0
    }
}

/// 事件落库结果。手机和眼镜的连接都不可靠，所以调用方必须能区分
/// "重连补发的旧事件"和"中间漏了事件"——后者要用 subscribe(fromSeq:) 补齐。
public enum ApplyOutcome: Sendable, Equatable {
    case applied
    case duplicate
    case gap(expected: Int)
    case unknownSession(String)
}

/// 客户端侧的会话状态机。纯值语义，不碰网络也不碰 UI，
/// 因此 bridge 的事件序列可以直接喂进来做断言。
public struct CrewStore: Sendable, Equatable {
    public private(set) var sessions: [String: SessionState] = [:]
    /// 展示顺序：新建的排在前面
    public private(set) var order: [String] = []

    public init() {}

    public var orderedSessions: [SessionState] {
        order.compactMap { sessions[$0] }
    }

    @discardableResult
    public mutating func apply(_ event: BridgeEvent) -> ApplyOutcome {
        if case let .sessionCreated(seq, session) = event {
            var state = SessionState(session: session)
            state.lastSeq = seq
            sessions[session.id] = state
            order.removeAll { $0 == session.id }
            order.insert(session.id, at: 0)
            return .applied
        }

        guard let sessionID = event.sessionID else {
            // 无会话归属的致命错误，交给上层展示，不进任何会话
            return .applied
        }
        guard var state = sessions[sessionID] else {
            return .unknownSession(sessionID)
        }
        if event.seq <= state.lastSeq { return .duplicate }
        if event.seq != state.lastSeq + 1 {
            return .gap(expected: state.lastSeq + 1)
        }
        state.lastSeq = event.seq

        switch event {
        case .sessionCreated:
            break

        case let .sessionStatus(_, _, status):
            state.session.status = status

        case .sessionClosed:
            state.session.status = .ended

        case let .blockAppended(_, _, block):
            state.blocks.append(block)

        case let .blockUpdated(_, _, blockID, patch):
            if let index = state.blocks.firstIndex(where: { $0.id == blockID }) {
                state.blocks[index] = state.blocks[index].applying(patch)
            }

        case let .approvalRequested(_, _, approval):
            state.pendingApprovals.append(approval)
            state.session.status = .awaitingApproval

        case let .approvalSettled(_, _, approvalID, _, _):
            state.pendingApprovals.removeAll { $0.id == approvalID }
            if state.pendingApprovals.isEmpty, state.session.status == .awaitingApproval {
                state.session.status = .running
            }

        case .turnCompleted:
            if state.pendingApprovals.isEmpty { state.session.status = .idle }
            // 流式中的 block 收尾：turn 结束后不该再有闪烁的光标
            for index in state.blocks.indices {
                state.blocks[index] = state.blocks[index]
                    .applying(TranscriptBlockPatch(streaming: false))
            }

        case let .bridgeError(_, _, message, fatal):
            state.blocks.append(.error(id: "err-\(event.seq)", message: message))
            if fatal { state.session.status = .error }
        }

        sessions[sessionID] = state
        return .applied
    }
}
