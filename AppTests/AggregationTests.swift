import AgentProtocol
import Foundation
import LensCrewCore
import Testing

@testable import LensCrew

private func makeApproval(id: String, requestedAtMs: Int64) -> ApprovalRequest {
    ApprovalRequest(
        id: id, kind: .shellCommand, title: "运行 shell 命令", detail: "npm test",
        cwd: nil, options: [], requestedAtMs: requestedAtMs
    )
}

private func makeSession(id: String, updatedAtMs: Int64) -> AgentSession {
    AgentSession(
        id: id, agent: .codex, nativeId: nil, workspaceRoot: "/tmp/x", title: "会话 \(id)",
        model: nil, status: .awaitingApproval,
        capabilities: AgentCapabilities(
            approvals: true, steering: true, interrupt: true,
            planMode: true, resume: true, streamingDeltas: true
        ),
        createdAtMs: 0, updatedAtMs: updatedAtMs
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

// 聚合用例会全局翻开 UITestFixture.isActive，串行跑避免影响并行用例
@Suite("多主机聚合与路由", .serialized)
@MainActor
struct AggregationTests {

    @Test("SessionKey 复合键：两台主机各有 s-1 时互不覆盖")
    func sessionKeyDoesNotCollideAcrossHosts() {
        let hostA = UUID()
        let hostB = UUID()
        let keyA = SessionKey(hostID: hostA, sessionID: "s-1")
        let keyB = SessionKey(hostID: hostB, sessionID: "s-1")
        #expect(keyA != keyB)
        #expect(Set([keyA, keyB]).count == 2)
        #expect(keyA == SessionKey(hostID: hostA, sessionID: "s-1"))
    }

    @Test("PendingApprovalItem 的 id 掺 hostID，跨主机同号审批不撞")
    func approvalItemIDMixesHostID() {
        let hostA = UUID()
        let hostB = UUID()
        let approval = makeApproval(id: "ap-1", requestedAtMs: 1)
        let session = makeSession(id: "s-1", updatedAtMs: 1)
        let itemA = PendingApprovalItem(
            hostID: hostA, hostName: "A", session: session, approval: approval
        )
        let itemB = PendingApprovalItem(
            hostID: hostB, hostName: "B", session: session, approval: approval
        )
        #expect(itemA.id != itemB.id)
        #expect(itemA.id == "\(hostA.uuidString)#ap-1")
        #expect(itemA.key == SessionKey(hostID: hostA, sessionID: "s-1"))
    }

    @Test("AggregatedSession 以复合键为身份")
    func aggregatedSessionIdentity() {
        let host = UUID()
        var state = SessionState(session: makeSession(id: "s-1", updatedAtMs: 7))
        state.pendingApprovals = [makeApproval(id: "ap-1", requestedAtMs: 3)]
        let item = AggregatedSession(hostID: host, hostName: "A", state: state)
        #expect(item.id == SessionKey(hostID: host, sessionID: "s-1"))
        #expect(item.key == item.id)
    }

    /// 走真实夹具路径（UITestFixture + FixtureBridgeConnection + HostLink 泵）驱动
    /// CrewViewModel 的计算属性：两台主机各有一条同名 s-fixture 会话与一条审批，
    /// 断言跨主机统排/倒序/掺号，而不是复刻一份排序逻辑来自测。
    @Test("夹具连接下 aggregatedSessions 跨主机按 updatedAtMs 统排、审批队列按 requestedAtMs 倒序")
    func aggregatesAcrossHostsThroughFixtureLinks() async throws {
        UITestFixture.isActive = true
        defer { UITestFixture.isActive = false }

        let model = CrewViewModel()
        // 夹具 store 已预置一台 active 主机；再加一台构成多主机
        _ = model.hosts.add(name: "第二台", host: "fixture2.invalid", port: 4311, token: "")
        #expect(model.hosts.hosts.count == 2)
        await model.connectAll()

        #expect(
            await waitUntil { model.aggregatedSessions.count == 2 },
            "两台主机的脚本会话都该进聚合列表"
        )
        #expect(
            await waitUntil { model.pendingApprovalItems.count == 2 },
            "两台主机的审批都该进聚合队列"
        )

        let sessions = model.aggregatedSessions
        // 同名 s-fixture 不互相覆盖：复合键各是各的
        #expect(Set(sessions.map(\.key)).count == 2)
        #expect(sessions.allSatisfy { $0.state.session.id == FixtureBridgeConnection.sessionID })
        // 夹具给每条连接错开 updatedAtMs：统排 = 新的在前
        #expect(
            sessions[0].state.session.updatedAtMs > sessions[1].state.session.updatedAtMs
        )

        let approvals = model.pendingApprovalItems
        #expect(approvals[0].approval.requestedAtMs > approvals[1].approval.requestedAtMs)
        #expect(Set(approvals.map(\.id)).count == 2)
        #expect(approvals.allSatisfy { $0.id.contains($0.hostID.uuidString) })
        #expect(approvals.allSatisfy { $0.approval.id == FixtureBridgeConnection.approvalID })
        // 会话按主机路由回查得到本体
        for item in approvals {
            #expect(model.sessionState(for: item.key)?.pendingApprovals.count == 1)
        }

        // 撤主机顺带停掉链接的泵与眼镜网关订阅，不给后续用例留后台任务
        for id in model.hosts.hosts.map(\.id) {
            await model.removeHost(id)
        }
    }
}
