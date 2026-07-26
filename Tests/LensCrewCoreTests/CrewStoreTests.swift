import AgentProtocol
import Testing

@testable import LensCrewCore

@Suite("客户端会话状态机")
struct CrewStoreTests {

    private let capabilities = AgentCapabilities(
        approvals: true, steering: true, interrupt: true,
        planMode: true, resume: true, streamingDeltas: true
    )

    private func created(_ id: String, seq: Int = 1) -> BridgeEvent {
        .sessionCreated(
            seq: seq,
            session: AgentSession(
                id: id, agent: .codex, nativeId: nil, workspaceRoot: "/tmp",
                title: "t", model: nil, status: .starting,
                capabilities: capabilities, modeId: nil, modes: [], models: [], reasoningEffort: nil,
                createdAtMs: 0, updatedAtMs: 0
            )
        )
    }

    @Test("新建会话排在列表最前")
    func newestSessionComesFirst() {
        var store = CrewStore()
        store.apply(created("a"))
        store.apply(created("b"))
        #expect(store.order == ["b", "a"])
    }

    @Test("重连补发的旧事件被识别为重复而不是重复入库")
    func detectsDuplicates() {
        var store = CrewStore()
        store.apply(created("a"))
        let append = BridgeEvent.blockAppended(
            seq: 2, sessionID: "a",
            block: .agentMessage(id: "b1", text: "你好", streaming: false)
        )
        #expect(store.apply(append) == .applied)
        #expect(store.apply(append) == .duplicate)
        #expect(store.sessions["a"]?.blocks.count == 1)
    }

    /// 手机和眼镜的连接都不可靠，漏事件必须能被发现，否则流水会静默错乱
    @Test("seq 断档被报告出来，且不落库")
    func reportsGaps() {
        var store = CrewStore()
        store.apply(created("a"))
        let outcome = store.apply(
            .blockAppended(
                seq: 5, sessionID: "a",
                block: .agentMessage(id: "b1", text: "x", streaming: false)
            )
        )
        #expect(outcome == .gap(expected: 2))
        #expect(store.sessions["a"]?.blocks.isEmpty == true)
        #expect(store.sessions["a"]?.lastSeq == 1)
    }

    @Test("未知会话的事件被拒绝而不是凭空造一个会话")
    func rejectsUnknownSession() {
        var store = CrewStore()
        let outcome = store.apply(
            .sessionStatus(seq: 1, sessionID: "ghost", status: .running)
        )
        #expect(outcome == .unknownSession("ghost"))
        #expect(store.sessions.isEmpty)
    }

    @Test("增量补丁改的是同一个 block")
    func appliesPatchToExistingBlock() {
        var store = CrewStore()
        store.apply(created("a"))
        store.apply(
            .blockAppended(
                seq: 2, sessionID: "a",
                block: .agentMessage(id: "b1", text: "你", streaming: true)
            )
        )
        store.apply(
            .blockUpdated(
                seq: 3, sessionID: "a", blockID: "b1",
                patch: TranscriptBlockPatch(appendText: "好")
            )
        )
        #expect(
            store.sessions["a"]?.blocks == [
                .agentMessage(id: "b1", text: "你好", streaming: true)
            ]
        )
    }

    @Test("审批到达把会话置为待审批，裁决后回到运行中")
    func tracksApprovalLifecycle() {
        var store = CrewStore()
        store.apply(created("a"))
        let approval = ApprovalRequest(
            id: "ap1", kind: .shellCommand, title: "运行 ls", detail: "ls",
            cwd: nil,
            options: [.init(id: "accept", label: "Approve", kind: .allow, scope: .once)],
            requestedAtMs: 0
        )
        store.apply(.approvalRequested(seq: 2, sessionID: "a", approval: approval))
        #expect(store.sessions["a"]?.session.status == .awaitingApproval)
        #expect(store.sessions["a"]?.pendingApprovals.count == 1)

        store.apply(
            .approvalSettled(
                seq: 3, sessionID: "a", approvalID: "ap1",
                optionID: "accept", outcome: .resolved
            )
        )
        #expect(store.sessions["a"]?.pendingApprovals.isEmpty == true)
        #expect(store.sessions["a"]?.session.status == .running)
    }

    @Test("turn 结束后没有 block 还停在流式态")
    func turnCompletionClearsStreamingFlags() {
        var store = CrewStore()
        store.apply(created("a"))
        store.apply(
            .blockAppended(
                seq: 2, sessionID: "a",
                block: .agentMessage(id: "b1", text: "x", streaming: true)
            )
        )
        store.apply(
            .turnCompleted(
                seq: 3, sessionID: "a", inputTokens: 10, outputTokens: 20,
                cachedInputTokens: 8, stopReason: .completed
            )
        )
        #expect(
            store.sessions["a"]?.blocks == [
                .agentMessage(id: "b1", text: "x", streaming: false)
            ]
        )
        #expect(store.sessions["a"]?.session.status == .idle)
    }

    @Test("待审批时 turn 结束不把状态抹成空闲")
    func keepsAwaitingApprovalAcrossTurnCompletion() {
        var store = CrewStore()
        store.apply(created("a"))
        store.apply(
            .approvalRequested(
                seq: 2, sessionID: "a",
                approval: ApprovalRequest(
                    id: "ap1", kind: .tool, title: "t", detail: "d", cwd: nil,
                    options: [], requestedAtMs: 0
                )
            )
        )
        store.apply(
            .turnCompleted(
                seq: 3, sessionID: "a", inputTokens: nil, outputTokens: nil,
                cachedInputTokens: nil, stopReason: nil
            )
        )
        #expect(store.sessions["a"]?.session.status == .awaitingApproval)
    }

    @Test("致命错误进流水并把会话标记为出错")
    func recordsFatalErrors() {
        var store = CrewStore()
        store.apply(created("a"))
        store.apply(
            .bridgeError(seq: 2, sessionID: "a", message: "app-server 退出", fatal: true)
        )
        #expect(store.sessions["a"]?.session.status == .error)
        #expect(store.sessions["a"]?.blocks.count == 1)
    }
}
