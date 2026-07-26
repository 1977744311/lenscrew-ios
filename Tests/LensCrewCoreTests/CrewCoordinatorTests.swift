import AgentProtocol
import BridgeLink
import Foundation
import GlassRenderer
import GlassesKit
import Testing

@testable import LensCrewCore

/// 端到端串起 bridge 事件 → 状态机 → 眼镜导航 → DAT 发送，
/// 全程用 Mock，不需要眼镜也不需要真的拉起三个 agent。
@Suite("协调层")
struct CrewCoordinatorTests {

    private let capabilities = AgentCapabilities(
        approvals: true, steering: true, interrupt: true,
        planMode: true, resume: true, streamingDeltas: true
    )

    private func session(_ id: String) -> AgentSession {
        AgentSession(
            id: id, agent: .codex, nativeId: "t1", workspaceRoot: "/tmp",
            title: "修登录", model: nil, status: .running,
            capabilities: capabilities, modeId: nil, modes: [],
            createdAtMs: 0, updatedAtMs: 0
        )
    }

    private func approval(_ id: String) -> ApprovalRequest {
        ApprovalRequest(
            id: id, kind: .shellCommand, title: "运行 npm test",
            detail: "npm test -- auth", cwd: "/tmp",
            options: [
                .init(id: "accept", label: "Approve", kind: .allow, scope: .once),
                .init(id: "decline", label: "Decline", kind: .deny, scope: .once),
            ],
            requestedAtMs: 0
        )
    }

    /// 节流窗口是 1 秒，测试里逐条喂事件会被合并。
    /// 这里只断言"发过"和"最后一屏是什么"，不断言发送条数。
    private func lastPayload(_ glasses: MockGlassesSession) async -> String? {
        await glasses.sentPayloads.last?.canonicalJSON
    }

    @Test("审批到达时眼镜自动切到审批卡")
    func approvalPreemptsGlasses() async throws {
        let bridge = MockBridgeConnection()
        let glasses = MockGlassesSession()
        try await glasses.start()
        try await glasses.attachDisplay()
        let coordinator = CrewCoordinator(bridge: bridge, glasses: glasses)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.ingest(
            .approvalRequested(seq: 2, sessionID: "s1", approval: approval("a1"))
        )

        #expect(
            await coordinator.screen == .approval(sessionID: "s1", approvalID: "a1", page: 0)
        )
        let payload = try #require(await lastPayload(glasses))
        #expect(payload.contains("approve:accept"))
        #expect(payload.contains("approve:decline"))
    }

    @Test("关闭自动亮屏后，审批到达不抢占眼镜屏，但照样进队列")
    func approvalDoesNotPreemptWhenAutoPresentDisabled() async throws {
        let bridge = MockBridgeConnection()
        let glasses = MockGlassesSession()
        try await glasses.start()
        try await glasses.attachDisplay()
        let coordinator = CrewCoordinator(bridge: bridge, glasses: glasses)
        await coordinator.setAutoPresentApprovals(false)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.tap(actionID: GlassAction.openSession("s1").actionID)
        await coordinator.ingest(
            .approvalRequested(seq: 2, sessionID: "s1", approval: approval("a1"))
        )

        // 眼镜停在原地，没有被切到审批卡
        #expect(
            await coordinator.screen == .transcript(sessionID: "s1", page: 0, following: true)
        )
        // 审批本身不受影响：仍然挂在会话上等手机端裁决
        #expect(await coordinator.sessions.first?.pendingApprovals.map(\.id) == ["a1"])
    }

    @Test("眼镜上点批准会把裁决发回 bridge，但不抢先撤卡")
    func tapSendsDecisionAndWaitsForConfirmation() async throws {
        let bridge = MockBridgeConnection()
        let glasses = MockGlassesSession()
        try await glasses.start()
        try await glasses.attachDisplay()
        let coordinator = CrewCoordinator(bridge: bridge, glasses: glasses)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.ingest(
            .approvalRequested(seq: 2, sessionID: "s1", approval: approval("a1"))
        )
        await coordinator.tap(actionID: GlassAction.resolveApproval(optionID: "accept").actionID)

        #expect(
            bridge.commands.contains(
                .resolveApproval(sessionID: "s1", approvalID: "a1", optionID: "accept")
            )
        )
        // bridge 还没确认，卡必须还在
        #expect(
            await coordinator.screen == .approval(sessionID: "s1", approvalID: "a1", page: 0)
        )

        await coordinator.ingest(
            .approvalSettled(
                seq: 3, sessionID: "s1", approvalID: "a1",
                optionID: "accept", outcome: .resolved
            )
        )
        #expect(await coordinator.screen == .sessionList)
    }

    @Test("seq 断档时自动续订补齐")
    func resubscribesOnGap() async throws {
        let bridge = MockBridgeConnection()
        let coordinator = CrewCoordinator(bridge: bridge)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.ingest(
            .blockAppended(
                seq: 7, sessionID: "s1",
                block: .agentMessage(id: "b1", text: "x", streaming: false)
            )
        )
        #expect(bridge.commands == [.subscribe(sessionID: "s1", fromSeq: 2)])
    }

    @Test("点会话行进入流水，返回回到列表")
    func navigatesIntoSessionAndBack() async throws {
        let bridge = MockBridgeConnection()
        let glasses = MockGlassesSession()
        try await glasses.start()
        try await glasses.attachDisplay()
        let coordinator = CrewCoordinator(bridge: bridge, glasses: glasses)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.tap(actionID: GlassAction.openSession("s1").actionID)
        #expect(
            await coordinator.screen == .transcript(sessionID: "s1", page: 0, following: true)
        )

        await coordinator.tap(actionID: GlassAction.back.actionID)
        #expect(await coordinator.screen == .sessionList)
    }

    @Test("跟随模式下流水增长会翻到最新页")
    func followsGrowingTranscript() async throws {
        let bridge = MockBridgeConnection()
        let coordinator = CrewCoordinator(bridge: bridge)

        await coordinator.ingest(.sessionCreated(seq: 1, session: session("s1")))
        await coordinator.tap(actionID: GlassAction.openSession("s1").actionID)
        for index in 0..<20 {
            await coordinator.ingest(
                .blockAppended(
                    seq: index + 2, sessionID: "s1",
                    block: .agentMessage(
                        id: "b\(index)", text: "第 \(index) 条消息", streaming: false
                    )
                )
            )
        }
        guard case let .transcript(_, page, following) = await coordinator.screen else {
            Issue.record("应当停在流水页")
            return
        }
        #expect(following)
        #expect(page > 0)
    }

    @Test("目标消失时退回列表而不是渲染空白屏")
    func fallsBackWhenTargetDisappears() {
        var store = CrewStore()
        store.apply(.sessionCreated(seq: 1, session: session("s1")))
        let result = GlassScreenRenderer.render(
            screen: .blockDetail(sessionID: "s1", blockID: "nonexistent", page: 0),
            store: store
        )
        #expect(result.pageCount == 1)
        if case let .flexBox(_, children) = result.node,
           case let .text(title, _, _) = children.first {
            #expect(title == "会话")
        } else {
            Issue.record("应当退回会话列表")
        }
    }
}

@Suite("眼镜发送节流")
struct DisplayThrottleTests {

    @Test("重复内容不重发")
    func skipsDuplicates() {
        var throttle = DisplayThrottle(minimumInterval: 1)
        #expect(throttle.decide(canonicalJSON: "a", now: 0) == .send)
        #expect(throttle.decide(canonicalJSON: "a", now: 5) == .skipDuplicate)
    }

    @Test("窗口内的更新推迟到窗口末尾")
    func defersWithinWindow() {
        var throttle = DisplayThrottle(minimumInterval: 1)
        #expect(throttle.decide(canonicalJSON: "a", now: 10) == .send)
        #expect(throttle.decide(canonicalJSON: "b", now: 10.4) == .deferUntil(11))
        #expect(throttle.decide(canonicalJSON: "b", now: 11) == .send)
    }

    @Test("重挂 display 后去重基准作废，同样的内容必须重发")
    func invalidateForcesResend() {
        var throttle = DisplayThrottle(minimumInterval: 1)
        #expect(throttle.decide(canonicalJSON: "a", now: 0) == .send)
        throttle.invalidate()
        #expect(throttle.decide(canonicalJSON: "a", now: 2) == .send)
    }

    @Test("immediate 绕过节流窗口，但去重照旧")
    func immediateBypassesWindowButNotDedup() {
        var throttle = DisplayThrottle(minimumInterval: 1)
        #expect(throttle.decide(canonicalJSON: "a", now: 0) == .send)
        #expect(throttle.decide(canonicalJSON: "b", now: 0.1, immediate: true) == .send)
        #expect(throttle.decide(canonicalJSON: "b", now: 0.2, immediate: true) == .skipDuplicate)
    }
}
