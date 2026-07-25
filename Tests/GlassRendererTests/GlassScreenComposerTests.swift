import AgentProtocol
import Testing

@testable import GlassRenderer

@Suite("眼镜屏布局生成")
struct GlassScreenComposerTests {

    private func actionIDs(in node: GlassNode) -> [String] {
        switch node {
        case let .flexBox(props, children):
            return (props.actionID.map { [$0] } ?? []) + children.flatMap(actionIDs(in:))
        case let .button(_, _, actionID):
            return [actionID]
        case .text, .icon:
            return []
        }
    }

    private func texts(in node: GlassNode) -> [String] {
        switch node {
        case let .flexBox(_, children):
            return children.flatMap(texts(in:))
        case let .text(content, _, _):
            return [content]
        case let .button(label, _, _):
            return [label]
        case .icon:
            return []
        }
    }

    @Test("会话列表每一行都可点进去")
    func sessionRowsAreTappable() {
        let node = GlassScreenComposer.sessionList([
            .init(id: "s1", agent: .codex, title: "修登录", status: .running, pendingApprovals: 0),
            .init(id: "s2", agent: .claude, title: "写测试", status: .awaitingApproval, pendingApprovals: 2),
        ])
        let ids = actionIDs(in: node)
        #expect(ids.contains(GlassAction.openSession("s1").actionID))
        #expect(ids.contains(GlassAction.openSession("s2").actionID))
        #expect(texts(in: node).contains { $0.contains("待审批 2") })
    }

    @Test("空列表给出明确提示而不是空白屏")
    func emptySessionListShowsPlaceholder() {
        #expect(texts(in: GlassScreenComposer.sessionList([])).contains("没有活动会话"))
    }

    @Test("审批卡的按钮完全由 adapter 给的选项决定")
    func approvalButtonsComeFromOptions() {
        let approval = ApprovalRequest(
            id: "a-1", kind: .shellCommand, title: "运行 rm -rf build",
            detail: "rm -rf build", cwd: "/tmp",
            options: [
                .init(id: "approved", label: "批准", kind: .allow),
                .init(id: "approved_for_session", label: "本会话都批", kind: .allowAlways),
                .init(id: "denied", label: "拒绝", kind: .deny),
            ],
            requestedAtMs: 0
        )
        let pages = TranscriptPaginator.detailPages(
            for: .error(id: "x", message: approval.detail), agent: .codex
        )
        let node = GlassScreenComposer.approvalCard(approval, detailPages: pages, index: 0)
        let ids = actionIDs(in: node)
        for option in approval.options {
            #expect(ids.contains(GlassAction.resolveApproval(optionID: option.id).actionID))
        }
    }

    @Test("跟随中不显示『最新』按钮，脱离跟随才显示")
    func latestButtonAppearsOnlyWhenBrowsingHistory() {
        let pages = [GlassPage(lines: [GlassLine("一")]), GlassPage(lines: [GlassLine("二")])]
        let following = GlassScreenComposer.transcriptPage(
            title: "t", agent: .codex, status: .running,
            pages: pages, index: 1, following: true
        )
        #expect(!actionIDs(in: following).contains(GlassAction.jumpToLatest.actionID))

        let browsing = GlassScreenComposer.transcriptPage(
            title: "t", agent: .codex, status: .running,
            pages: pages, index: 0, following: false
        )
        #expect(actionIDs(in: browsing).contains(GlassAction.jumpToLatest.actionID))
    }

    @Test("越界页码被夹住而不是崩溃")
    func clampsOutOfRangePageIndex() {
        let pages = [GlassPage(lines: [GlassLine("唯一一页")])]
        let node = GlassScreenComposer.transcriptPage(
            title: "t", agent: .codex, status: .idle,
            pages: pages, index: 99, following: true
        )
        #expect(texts(in: node).contains("唯一一页"))
        #expect(texts(in: node).contains("1/1"))
    }

    @Test("同样入参产出同样的稳定序列化，可做快照比对与整屏去重")
    func canonicalJSONIsStable() throws {
        let make = {
            GlassScreenComposer.sessionList([
                .init(
                    id: "s1", agent: .codex, title: "修登录",
                    status: .running, pendingApprovals: 0
                )
            ])
        }
        let first = try GlassNodeEncoder.canonicalJSON(make())
        let second = try GlassNodeEncoder.canonicalJSON(make())
        #expect(first == second)
        #expect(first.contains("session:s1"))
    }
}
