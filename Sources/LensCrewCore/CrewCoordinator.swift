import AgentProtocol
import BridgeLink
import Foundation
import GlassRenderer
import GlassesKit

/// 把 bridge 事件流、客户端状态机、眼镜导航和 DAT 发送串成一个系统。
///
/// 眼镜不保存状态（DAT 的明确约定），所以导航状态机跑在手机上，
/// 眼镜只是它的一块投影屏；眼镜和手机看到的是同一份 `CrewStore`。
/// 给 UI 的状态快照。眼镜和手机看同一份数据，只是呈现方式不同。
public struct CrewSnapshot: Sendable, Equatable {
    public var sessions: [SessionState]
    public var glassScreen: GlassScreen

    public init(sessions: [SessionState], glassScreen: GlassScreen) {
        self.sessions = sessions
        self.glassScreen = glassScreen
    }
}

public actor CrewCoordinator {
    private let bridge: any BridgeConnecting
    private let dispatcher: DisplayDispatcher?
    private let budget: GlassLayoutBudget
    private let snapshotBus = StreamBroadcaster<CrewSnapshot>(replaysLatest: true)

    private var store = CrewStore()
    private var navigator = GlassNavigator()
    /// 审批到达时是否自动把眼镜切到审批卡。默认开——agent 卡在那里等人；
    /// 但用户在专注看流水时可能不想被抢屏，手机设置里可以关掉。
    /// 关掉只影响"抢屏"，审批照样进队列、结清后的 dismiss 逻辑也不变。
    private var autoPresentApprovals = true

    public init(
        bridge: any BridgeConnecting,
        glasses: (any GlassesSessionProviding)? = nil,
        budget: GlassLayoutBudget = .default
    ) {
        self.bridge = bridge
        self.dispatcher = glasses.map { DisplayDispatcher(session: $0) }
        self.budget = budget
    }

    public var sessions: [SessionState] { store.orderedSessions }
    public var screen: GlassScreen { navigator.screen }

    public func setAutoPresentApprovals(_ enabled: Bool) {
        autoPresentApprovals = enabled
    }

    /// 状态快照流。UI 不该去轮询 actor——每次状态变化推一份，SwiftUI 直接跟着走。
    public nonisolated var snapshots: AsyncStream<CrewSnapshot> {
        snapshotBus.subscribe()
    }

    // MARK: - 手机端动作

    public func createSession(
        agent: AgentKind, workspaceRoot: String,
        model: String? = nil, modeID: String? = nil
    ) async throws {
        try await bridge.send(
            .createSession(
                agent: agent, workspaceRoot: workspaceRoot, model: model, modeID: modeID
            )
        )
    }

    public func sendMessage(_ text: String, to sessionID: String) async throws {
        try await bridge.send(.sendMessage(sessionID: sessionID, text: text))
    }

    /// 切换会话模式；生效以 bridge 回推的 sessionUpdated（modeId 变化）为准
    public func setSessionMode(_ sessionID: String, modeID: String) async throws {
        try await bridge.send(.setSessionMode(sessionID: sessionID, modeID: modeID))
    }

    /// 切换会话模型；生效以 bridge 回推的 sessionUpdated（model 变化）为准
    public func setSessionModel(_ sessionID: String, modelID: String) async throws {
        try await bridge.send(.setSessionModel(sessionID: sessionID, modelID: modelID))
    }

    public func interrupt(_ sessionID: String) async throws {
        try await bridge.send(.interrupt(sessionID: sessionID))
    }

    public func closeSession(_ sessionID: String) async throws {
        try await bridge.send(.closeSession(sessionID: sessionID))
    }

    /// 手机上裁决审批。和眼镜上点按走同一条路：都不做乐观关闭，
    /// 等 bridge 的 approvalSettled 回来才撤卡，否则两块屏会显示互相矛盾的状态。
    public func resolveApproval(
        sessionID: String, approvalID: String, optionID: String
    ) async throws {
        try await bridge.send(
            .resolveApproval(
                sessionID: sessionID, approvalID: approvalID, optionID: optionID
            )
        )
    }

    /// 两条消费循环：bridge 下行事件、眼镜上行点击。
    public func run(glasses: (any GlassesSessionProviding)? = nil) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [bridge] in
                for await event in bridge.events {
                    await self.ingest(event)
                }
            }
            if let glasses {
                group.addTask {
                    for await actionID in glasses.displayActions {
                        await self.tap(actionID: actionID)
                    }
                }
            }
        }
    }

    // MARK: - 下行

    public func ingest(_ event: BridgeEvent) async {
        switch store.apply(event) {
        case .duplicate:
            return
        case let .gap(expected):
            // 漏了事件，续订补齐；不补的话流水会静默错乱
            if let sessionID = event.sessionID {
                try? await bridge.send(.subscribe(sessionID: sessionID, fromSeq: expected))
            }
            return
        case .unknownSession(let sessionID):
            try? await bridge.send(.subscribe(sessionID: sessionID, fromSeq: 0))
            return
        case .applied:
            break
        }

        // seq 0 的 sessionCreated 是接入补发的合成快照，只有元数据——流水与
        // 待审批要靠重放窗口拉回来，否则冷启动的客户端会看到"等你审批"
        // 却点不开任何东西。fromSeq 取 1 而不是 0：replay(0) 会再回一条
        // seq 0 快照，那就循环了。
        if case let .sessionCreated(seq, session) = event, seq == 0 {
            try? await bridge.send(.subscribe(sessionID: session.id, fromSeq: 1))
        }

        switch event {
        case let .approvalRequested(_, sessionID, approval):
            if autoPresentApprovals {
                navigator.presentApproval(sessionID: sessionID, approvalID: approval.id)
            }
        case let .approvalSettled(_, _, approvalID, _, _):
            navigator.dismissApproval(approvalID)
        case .blockAppended, .blockUpdated:
            navigator.followLatest(pageCount: currentPageCount())
        default:
            break
        }

        await renderToGlasses()
    }

    // MARK: - 上行

    public func tap(actionID: String) async {
        guard let action = GlassAction(actionID: actionID) else { return }

        if case let .resolveApproval(optionID) = action,
           case let .approval(sessionID, approvalID, _) = navigator.screen {
            // 不做乐观关闭：等 bridge 的 approvalSettled 回来再撤卡，
            // 否则 bridge 拒绝时眼镜上已经显示"批准了"，与真实状态不符。
            try? await bridge.send(
                .resolveApproval(
                    sessionID: sessionID, approvalID: approvalID, optionID: optionID
                )
            )
            return
        }

        navigator.handle(action, pageCount: currentPageCount())
        await renderToGlasses()
    }

    // MARK: - 渲染

    /// display 重挂后调用：眼镜屏已被清空，去重基准必须作废，
    /// 否则重连后第一屏会被当成重复内容吞掉。
    public func displayReattached() async {
        await dispatcher?.invalidateCache()
        await renderToGlasses()
    }

    private func publishSnapshot() {
        snapshotBus.send(
            CrewSnapshot(sessions: store.orderedSessions, glassScreen: navigator.screen)
        )
    }

    private func renderToGlasses() async {
        publishSnapshot()
        guard let dispatcher else { return }
        let result = GlassScreenRenderer.render(
            screen: navigator.screen, store: store, budget: budget
        )
        // 审批卡绕过节流：agent 正卡在那里等人，压一秒才上屏没有道理
        let immediate: Bool
        if case .approval = navigator.screen { immediate = true } else { immediate = false }
        try? await dispatcher.submit(result.node, immediate: immediate)
    }

    private func currentPageCount() -> Int {
        GlassScreenRenderer.render(
            screen: navigator.screen, store: store, budget: budget
        ).pageCount
    }
}
