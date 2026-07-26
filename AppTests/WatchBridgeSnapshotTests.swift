import AgentProtocol
import Foundation
import LensCrewCore
import Testing

@testable import LensCrew

private let capabilities = AgentCapabilities(
    approvals: true, steering: true, interrupt: true,
    planMode: true, resume: true, streamingDeltas: true
)

private func makeApprovalItem(
    ordinal: Int, hostID: UUID, hostName: String = "Mac", detail: String = "npm test"
) -> PendingApprovalItem {
    let session = AgentSession(
        id: "s-\(ordinal)", agent: .codex, nativeId: nil, workspaceRoot: "/tmp/x",
        title: "会话 \(ordinal)", model: nil, status: .awaitingApproval,
        capabilities: capabilities, createdAtMs: 0, updatedAtMs: Int64(ordinal)
    )
    let approval = ApprovalRequest(
        id: "ap-\(ordinal)", kind: .shellCommand, title: "运行 shell 命令", detail: detail,
        cwd: nil,
        options: [ApprovalOption(id: "accept", label: "批准", kind: .allow, scope: .once)],
        requestedAtMs: Int64(1000 - ordinal)
    )
    return PendingApprovalItem(
        hostID: hostID, hostName: hostName, session: session, approval: approval
    )
}

private func makeAggregatedSession(
    ordinal: Int, hostID: UUID, hostName: String = "Mac",
    blocks: [TranscriptBlock] = []
) -> AggregatedSession {
    var state = SessionState(
        session: AgentSession(
            id: "s-\(ordinal)", agent: .claude, nativeId: nil, workspaceRoot: "/tmp/x",
            title: "会话 \(ordinal)", model: nil, status: .running,
            capabilities: capabilities, createdAtMs: 0, updatedAtMs: Int64(ordinal)
        )
    )
    state.blocks = blocks
    return AggregatedSession(hostID: hostID, hostName: hostName, state: state)
}

// buildSnapshot 是 @MainActor 类型的静态纯映射，用例统一上主线程
@Suite("WatchBridge.buildSnapshot")
@MainActor
struct WatchBridgeSnapshotTests {

    @Test("审批裁到 8 条、detail 截 800 字，顺序保持输入序")
    func clipsApprovals() throws {
        let host = UUID()
        let longDetail = String(repeating: "长", count: 900)
        let items = (0..<10).map {
            makeApprovalItem(ordinal: $0, hostID: host, detail: longDetail)
        }

        let snapshot = WatchBridge.buildSnapshot(approvals: items, sessions: [])
        #expect(snapshot.approvals.count == WatchWire.maxApprovals)
        #expect(snapshot.approvals.map(\.approval.id) == (0..<8).map { "ap-\($0)" })
        let first = try #require(snapshot.approvals.first)
        #expect(first.approval.detail.count == WatchWire.maxDetailChars + 1, "800 字 + 省略号")
        #expect(first.approval.detail.hasSuffix("…"))
        // 复合 id 与手机侧 PendingApprovalItem 同构
        #expect(first.id == "\(host.uuidString)#ap-0")
        #expect(first.hostID == host)
        #expect(first.sessionID == "s-0")
    }

    @Test("会话裁到 12 条、recentLines 取末 3 块且逐行截 120 字，shell 行标 mono")
    func clipsSessions() throws {
        let host = UUID()
        let longText = String(repeating: "a", count: 200)
        let blocks: [TranscriptBlock] = [
            .userMessage(id: "b1", text: "第一块（应被裁掉）", imageCount: 0),
            .agentMessage(id: "b2", text: "第二块（应被裁掉）", streaming: false),
            .reasoning(id: "b3", text: "内部推理", streaming: false),
            .shellCommand(
                id: "b4", command: "npm test", cwd: nil, output: "",
                exitCode: nil, status: .pending
            ),
            .agentMessage(id: "b5", text: longText, streaming: false),
        ]
        var sessions = [makeAggregatedSession(ordinal: 0, hostID: host, blocks: blocks)]
        sessions += (1..<14).map { makeAggregatedSession(ordinal: $0, hostID: host) }

        let snapshot = WatchBridge.buildSnapshot(approvals: [], sessions: sessions)
        #expect(snapshot.sessions.count == WatchWire.maxSessions)

        let lines = try #require(snapshot.sessions.first?.recentLines)
        #expect(lines.count == WatchWire.maxRecentLines, "只带最近 3 块")
        // 与手机会话卡同一份 blockPreview 预渲染
        #expect(lines[0] == WatchTranscriptLine(text: "思考完成", mono: false))
        #expect(lines[1] == WatchTranscriptLine(text: "$ npm test — 等待批准", mono: true))
        #expect(lines[2].mono == false)
        #expect(lines[2].text.count == WatchWire.maxLineChars + 1, "120 字 + 省略号")
        #expect(lines[2].text.hasSuffix("…"))
    }

    @Test("Equatable 是去重基准：同输入同快照，输入变了快照必变")
    func snapshotEquatableDrivesDedup() {
        let host = UUID()
        let approvals = [makeApprovalItem(ordinal: 1, hostID: host)]
        let sessions = [makeAggregatedSession(ordinal: 1, hostID: host)]

        let first = WatchBridge.buildSnapshot(approvals: approvals, sessions: sessions)
        let second = WatchBridge.buildSnapshot(approvals: approvals, sessions: sessions)
        #expect(first == second, "同输入必须产出相等快照，pushIfChanged 才能去重")

        let changed = WatchBridge.buildSnapshot(
            approvals: [makeApprovalItem(ordinal: 1, hostID: host, detail: "rm -rf /tmp/x")],
            sessions: sessions
        )
        #expect(first != changed)
    }

    @Test("多主机标注：单台不标、跨审批与会话的并集算多台")
    func multiHostAnnotation() {
        let hostA = UUID()
        let hostB = UUID()

        let single = WatchBridge.buildSnapshot(
            approvals: [makeApprovalItem(ordinal: 1, hostID: hostA)],
            sessions: [makeAggregatedSession(ordinal: 1, hostID: hostA)]
        )
        #expect(!single.multiHost)

        // 审批在 A、会话在 B：并集两台，行上要带主机名
        let mixed = WatchBridge.buildSnapshot(
            approvals: [makeApprovalItem(ordinal: 1, hostID: hostA)],
            sessions: [makeAggregatedSession(ordinal: 1, hostID: hostB)]
        )
        #expect(mixed.multiHost)
        #expect(WatchBridge.buildSnapshot(approvals: [], sessions: []) == .empty)
    }

    @Test("额度条目裁到 4 条、单条窗口裁到 4 个，字段原样透传")
    func clipsQuotas() throws {
        let host = UUID()
        let windows = (0..<6).map {
            QuotaWindow(
                id: "codex/w\($0)", label: nil, usedPercent: 10 * $0,
                windowDurationMins: 10_080, resetsAt: nil
            )
        }
        let quotas = (0..<6).map { ordinal in
            HostQuota(
                hostID: host, hostName: "Mac \(ordinal)",
                quota: AgentQuotaSnapshot(
                    agent: .codex, planType: "pro", windows: windows,
                    capturedAtMs: Int64(ordinal)
                )
            )
        }

        let snapshot = WatchBridge.buildSnapshot(
            approvals: [], sessions: [], quotas: quotas, connectedHosts: 3
        )
        #expect(snapshot.quotas.count == WatchWire.maxQuotaEntries)
        let first = try #require(snapshot.quotas.first)
        #expect(first.windows.count == WatchWire.maxQuotaWindows)
        #expect(first.windows[0].usedPercent == 0)
        #expect(first.planType == "pro")
        #expect(first.id == "\(host.uuidString)#codex")
        #expect(snapshot.connectedHosts == 3)
    }

    @Test("complication 指纹按 5% 分档：小抖动不换指纹、跨档必换")
    func complicationFingerprintBuckets() {
        let host = UUID()
        func snapshot(usedPercent: Int) -> WatchSnapshot {
            WatchBridge.buildSnapshot(
                approvals: [], sessions: [],
                quotas: [
                    HostQuota(
                        hostID: host, hostName: "Mac",
                        quota: AgentQuotaSnapshot(
                            agent: .codex, planType: nil,
                            windows: [
                                QuotaWindow(
                                    id: "codex/primary", label: nil, usedPercent: usedPercent,
                                    windowDurationMins: 10_080, resetsAt: nil
                                )
                            ],
                            capturedAtMs: Int64(usedPercent)  // 采集时刻不该影响指纹
                        )
                    )
                ],
                connectedHosts: 1
            )
        }
        let base = WatchBridge.complicationFingerprint(snapshot(usedPercent: 11))
        #expect(WatchBridge.complicationFingerprint(snapshot(usedPercent: 13)) == base, "同档 5% 内不换")
        #expect(WatchBridge.complicationFingerprint(snapshot(usedPercent: 16)) != base, "跨档必换")

        // 待批数进指纹：审批出现表盘就该有机会立刻刷新
        let withApproval = WatchBridge.buildSnapshot(
            approvals: [makeApprovalItem(ordinal: 1, hostID: host)], sessions: []
        )
        #expect(
            WatchBridge.complicationFingerprint(withApproval)
                != WatchBridge.complicationFingerprint(.empty)
        )
    }
}
