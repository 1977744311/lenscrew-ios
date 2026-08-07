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
    /// 全量重建（subscribe fromSeq:0）每会话最短间隔，避免超长会话抖屏
    private static let fullRebuildCooldown: TimeInterval = 10

    private let bridge: any BridgeConnecting
    private let dispatcher: DisplayDispatcher?
    private let budget: GlassLayoutBudget
    private let now: @Sendable () -> Date
    private let snapshotBus = StreamBroadcaster<CrewSnapshot>(replaysLatest: true)
    /// nil = 清掉宿主错误条；非 nil = 上抛可见错误（如「流水可能不完整」）
    private let hostErrorBus = StreamBroadcaster<String?>(replaysLatest: false)

    private var store = CrewStore()
    private var navigator = GlassNavigator()
    /// 审批到达时是否自动把眼镜切到审批卡。默认开——agent 卡在那里等人；
    /// 但用户在专注看流水时可能不想被抢屏，手机设置里可以关掉。
    /// 关掉只影响"抢屏"，审批照样进队列、结清后的 dismiss 逻辑也不变。
    private var autoPresentApprovals = true
    /// 已对某会话发出增量 subscribe、尚等重放把断档补齐
    private var awaitingGapRepair: [String: Int] = [:]
    /// 每会话最近一次全量重建时间（限频）
    private var lastFullRebuildAt: [String: Date] = [:]
    /// 最近一次上抛的宿主错误（nil = 已清除）；单测可同步读，UI 走 hostErrors 流
    private var lastHostError: String?

    public init(
        bridge: any BridgeConnecting,
        glasses: (any GlassesSessionProviding)? = nil,
        budget: GlassLayoutBudget = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.dispatcher = glasses.map { DisplayDispatcher(session: $0) }
        self.budget = budget
        self.now = now
    }

    public var sessions: [SessionState] { store.orderedSessions }
    public var screen: GlassScreen { navigator.screen }
    /// 最近一次宿主错误文案；成功补齐后为 nil
    public var reportedHostError: String? { lastHostError }

    public func setAutoPresentApprovals(_ enabled: Bool) {
        autoPresentApprovals = enabled
    }

    /// 状态快照流。UI 不该去轮询 actor——每次状态变化推一份，SwiftUI 直接跟着走。
    public nonisolated var snapshots: AsyncStream<CrewSnapshot> {
        snapshotBus.subscribe()
    }

    /// 宿主可见错误。subscribe 补齐失败等不能静默；nil 表示清掉旧错误。
    public nonisolated var hostErrors: AsyncStream<String?> {
        hostErrorBus.subscribe()
    }

    // MARK: - 手机端动作

    public func createSession(
        agent: AgentKind, workspaceRoot: String,
        model: String? = nil, modeID: String? = nil, reasoningEffort: String? = nil
    ) async throws {
        try await bridge.send(
            .createSession(
                agent: agent, workspaceRoot: workspaceRoot, model: model, modeID: modeID,
                reasoningEffort: reasoningEffort
            )
        )
    }

    /// 续接死会话：原生会话仍在各 CLI 的状态目录里，bridge 会开一个新会话行接上它。
    /// 新会话以 sessionCreated 广播出现，旧行由调用方自行关闭。
    public func resumeSession(
        agent: AgentKind, nativeID: String, workspaceRoot: String
    ) async throws {
        try await bridge.send(
            .resumeSession(agent: agent, nativeID: nativeID, workspaceRoot: workspaceRoot))
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

    /// 切换推理档（仅 codex）；生效以 sessionUpdated（reasoningEffort 变化）为准
    public func setSessionReasoningEffort(_ sessionID: String, effort: String) async throws {
        try await bridge.send(
            .setSessionReasoningEffort(sessionID: sessionID, effort: effort))
    }

    public func interrupt(_ sessionID: String) async throws {
        try await bridge.send(.interrupt(sessionID: sessionID))
    }

    public func closeSession(_ sessionID: String) async throws {
        try await bridge.send(.closeSession(sessionID: sessionID))
    }

    /// 只清客户端侧的残留（bridge 已不认识这个会话时用），并推一份新快照
    public func dropSession(_ sessionID: String) async {
        store.removeSession(sessionID)
        awaitingGapRepair[sessionID] = nil
        lastFullRebuildAt[sessionID] = nil
        await renderToGlasses()
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
                await repairGap(sessionID: sessionID, expected: expected)
            }
            return
        case .unknownSession(let sessionID):
            await subscribeOrReport(sessionID: sessionID, fromSeq: 0, markDesyncedOnFail: false)
            return
        case .applied:
            noteSuccessfulApply(event)
        }

        // seq 0 的 sessionCreated 是接入补发的合成快照，只有元数据——流水与
        // 待审批要靠重放窗口拉回来，否则冷启动的客户端会看到"等你审批"
        // 却点不开任何东西。fromSeq 取 1 而不是 0：replay(0) 会再回一条
        // seq 0 快照，那就循环了。
        if case let .sessionCreated(seq, session) = event, seq == 0 {
            await subscribeOrReport(
                sessionID: session.id, fromSeq: 1, markDesyncedOnFail: true
            )
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

    // MARK: - 断档补齐

    /// 先增量 subscribe；失败或重放后仍断档 → 限频全量重建；再失败则标 desynced。
    private func repairGap(sessionID: String, expected: Int) async {
        if isDesynced(sessionID) {
            if let last = lastFullRebuildAt[sessionID],
               now().timeIntervalSince(last) < Self.fullRebuildCooldown {
                reportHostError("流水可能不完整")
                return
            }
            // 冷却结束：直接再试全量，增量对已对不齐的会话无济于事
            awaitingGapRepair[sessionID] = nil
            await fullRebuild(sessionID: sessionID)
            return
        }

        let stillGapped = awaitingGapRepair[sessionID] != nil
        if !stillGapped {
            do {
                try await bridge.send(.subscribe(sessionID: sessionID, fromSeq: expected))
                awaitingGapRepair[sessionID] = expected
                return
            } catch {
                // 增量失败，落入全量重建
            }
        }
        awaitingGapRepair[sessionID] = nil
        await fullRebuild(sessionID: sessionID)
    }

    private func isDesynced(_ sessionID: String) -> Bool {
        store.orderedSessions.contains { $0.session.id == sessionID && $0.isDesynced }
    }

    private func fullRebuild(sessionID: String) async {
        let instant = now()
        if let last = lastFullRebuildAt[sessionID],
           instant.timeIntervalSince(last) < Self.fullRebuildCooldown {
            markDesyncedAndReport(sessionID)
            return
        }
        lastFullRebuildAt[sessionID] = instant
        // fromSeq:0 早于窗口时 hub 会先补一条 sessionCreated 再重放，客户端整表重建
        do {
            try await bridge.send(.subscribe(sessionID: sessionID, fromSeq: 0))
            reportHostError(nil)
        } catch {
            markDesyncedAndReport(sessionID)
        }
    }

    private func subscribeOrReport(
        sessionID: String, fromSeq: Int, markDesyncedOnFail: Bool
    ) async {
        do {
            try await bridge.send(.subscribe(sessionID: sessionID, fromSeq: fromSeq))
        } catch {
            if markDesyncedOnFail {
                markDesyncedAndReport(sessionID)
            } else {
                reportHostError("流水可能不完整")
            }
        }
    }

    private func noteSuccessfulApply(_ event: BridgeEvent) {
        guard let sessionID = event.sessionID else { return }
        if awaitingGapRepair.removeValue(forKey: sessionID) != nil {
            reportHostError(nil)
        }
        if store.orderedSessions.contains(where: { $0.session.id == sessionID && $0.isDesynced }) {
            store.clearDesynced(sessionID)
            reportHostError(nil)
        }
    }

    private func markDesyncedAndReport(_ sessionID: String) {
        store.markDesynced(sessionID)
        reportHostError("流水可能不完整")
        publishSnapshot()
    }

    private func reportHostError(_ message: String?) {
        lastHostError = message
        hostErrorBus.send(message)
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
