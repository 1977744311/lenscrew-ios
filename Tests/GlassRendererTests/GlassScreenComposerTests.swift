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

    /// 带样式与颜色的文本节点：mockup 校准要断言"哪行白哪行绿"，光看字符串不够
    private func textNodes(
        in node: GlassNode
    ) -> [(text: String, style: GlassTextStyle, color: GlassTextColor)] {
        switch node {
        case let .flexBox(_, children):
            return children.flatMap(textNodes(in:))
        case let .text(content, style, color):
            return [(content, style, color)]
        case .button, .icon:
            return []
        }
    }

    private func buttons(in node: GlassNode) -> [(label: String, style: GlassButtonStyle)] {
        switch node {
        case let .flexBox(_, children):
            return children.flatMap(buttons(in:))
        case let .button(label, style, _):
            return [(label, style)]
        case .text, .icon:
            return []
        }
    }

    private func icons(in node: GlassNode) -> [GlassIconName] {
        switch node {
        case let .flexBox(_, children):
            return children.flatMap(icons(in:))
        case let .icon(name):
            return [name]
        case .text, .button:
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
                .init(id: "accept", label: "Approve", kind: .allow, scope: .once),
                .init(
                    id: "acceptForSession", label: "Approve for session",
                    kind: .allow, scope: .session
                ),
                .init(
                    id: "acceptWithAmendment", label: "Always approve",
                    kind: .allow, scope: .persistent
                ),
                .init(id: "decline", label: "Decline", kind: .deny, scope: .once),
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

    /// 三个运行时的原生文案各不相同（"Allow once" / "总是允许" / "acceptForSession"），
    /// 而在只能 tap 的小屏上，作用范围必须用同一套词区分开——所以按钮文案自己推导，
    /// 不用 adapter 给的 label。
    @Test("按钮文案由 kind 与 scope 推导，三档作用范围各不相同")
    func derivesButtonLabelsFromKindAndScope() {
        let approval = ApprovalRequest(
            id: "a-1", kind: .shellCommand, title: "运行 rm -rf build",
            detail: "rm -rf build", cwd: nil,
            options: [
                .init(id: "o1", label: "Allow once", kind: .allow, scope: .once),
                .init(id: "o2", label: "Allow for session", kind: .allow, scope: .session),
                .init(id: "o3", label: "Allow always", kind: .allow, scope: .persistent),
                .init(id: "o4", label: "Reject", kind: .deny, scope: .once),
                .init(id: "o5", label: "Reject always", kind: .deny, scope: .persistent),
            ],
            requestedAtMs: 0
        )
        let node = GlassScreenComposer.approvalCard(
            approval, detailPages: [GlassPage(lines: [])], index: 0
        )
        let rendered = texts(in: node)
        for label in ["批准", "本会话都批", "永久批准", "拒绝", "永久拒绝"] {
            #expect(rendered.contains(label), "缺少按钮文案 \(label)")
        }
        // adapter 的原文不该出现在屏上
        #expect(!rendered.contains("Allow always"))
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

    // MARK: - mockup 对照（G1–G4）

    @Test("G1 会话列表：行=白色 body 标题+绿色 meta，底部白色汇总脚注")
    func sessionListMatchesMockupRowStructure() {
        let node = GlassScreenComposer.sessionList([
            .init(
                id: "s1", agent: .codex, title: "lenscrew-demo",
                status: .awaitingApproval, pendingApprovals: 1
            ),
            .init(
                id: "s2", agent: .cursor, title: "Summarize Workspace",
                status: .running, pendingApprovals: 0
            ),
            .init(
                id: "s3", agent: .claude, title: "重构流水分页器",
                status: .idle, pendingApprovals: 0
            ),
        ])
        let rendered = textNodes(in: node)
        // 屏顶 heading 只属于「会话」，行标题降一档用 body-primary
        #expect(rendered.first?.text == "会话" && rendered.first?.style == .heading)
        #expect(rendered.contains {
            $0.text == "lenscrew-demo" && $0.style == .body && $0.color == .primary
        })
        // meta 行「agent · 状态」是绿色（secondary）
        #expect(rendered.contains {
            $0.text == "Codex · 待审批 1" && $0.style == .meta && $0.color == .secondary
        })
        #expect(rendered.contains { $0.text == "Cursor · 运行中" })
        #expect(rendered.contains { $0.text == "Claude · 空闲" })
        // 底部操作提示是白色 meta，且是整屏最后一个文本节点
        #expect(rendered.last?.text == "点按会话进入 · 共 3 个")
        #expect(rendered.last?.style == .meta && rendered.last?.color == .primary)
        // 空列表不该出现"点按进入"的提示
        #expect(!texts(in: GlassScreenComposer.sessionList([])).contains {
            $0.contains("点按会话进入")
        })
    }

    @Test("G1 状态词表与 mockup 一致，starting 显示为「计划中」")
    func sessionStatusVocabularyMatchesMockup() {
        let cases: [(SessionStatus, String)] = [
            (.starting, "计划中"), (.idle, "空闲"), (.running, "运行中"),
            (.awaitingApproval, "待审批"), (.error, "出错"), (.ended, "已结束"),
        ]
        for (status, expected) in cases {
            let node = GlassScreenComposer.sessionList([
                .init(id: "s", agent: .codex, title: "t", status: status, pendingApprovals: 0)
            ])
            #expect(
                texts(in: node).contains("Codex · \(expected)"),
                "状态 \(status) 的文案应为「\(expected)」"
            )
        }
    }

    @Test("G2 流水页头：标题 heading + 绿色「agent · 状态 · 跟随」meta")
    func transcriptHeaderMatchesMockup() {
        let pages = [GlassPage(lines: [GlassLine("正文")])]
        let following = GlassScreenComposer.transcriptPage(
            title: "lenscrew-demo", agent: .codex, status: .running,
            pages: pages, index: 0, following: true
        )
        let rendered = textNodes(in: following)
        #expect(rendered.contains {
            $0.text == "lenscrew-demo" && $0.style == .heading && $0.color == .primary
        })
        #expect(rendered.contains {
            $0.text == "Codex · 运行中 · 跟随" && $0.style == .meta && $0.color == .secondary
        })
        // 「· 跟随」尾巴只属于跟随态
        let browsing = GlassScreenComposer.transcriptPage(
            title: "lenscrew-demo", agent: .codex, status: .running,
            pages: pages, index: 0, following: false
        )
        #expect(texts(in: browsing).contains("Codex · 运行中"))
        #expect(!texts(in: browsing).contains { $0.contains("跟随") })
    }

    @Test("G3 块详情：kind 标识翻译成中文，头/正文/翻页与 mockup 同构")
    func blockDetailMatchesMockup() {
        let pages = TranscriptPaginator.detailPages(
            for: .shellCommand(
                id: "b1", command: "ls -la", cwd: "/tmp/lenscrew-demo",
                output: "total 16", exitCode: 0, status: .ok
            ),
            agent: .codex
        )
        // GlassScreenRenderer 传的 title 是 block.kind 的英文标识，屏上必须是中文
        let node = GlassScreenComposer.blockDetail(title: "shellCommand", pages: pages, index: 0)
        let rendered = textNodes(in: node)
        #expect(rendered.first?.text == "Shell 命令")
        #expect(!texts(in: node).contains("shellCommand"))
        // mockup 的头两行：$ 命令（heading）+ 状态（绿 meta）
        #expect(rendered.contains { $0.text == "$ ls -la" && $0.style == .heading })
        #expect(rendered.contains {
            $0.text == "完成 · 退出码 0" && $0.style == .meta && $0.color == .secondary
        })
        // 输出行是白色 body 正文
        #expect(rendered.contains {
            $0.text == "total 16" && $0.style == .body && $0.color == .primary
        })
        // 底部同款翻页 [←] n/m [→]
        let ids = actionIDs(in: node)
        #expect(ids.contains(GlassAction.pagePrevious.actionID))
        #expect(ids.contains(GlassAction.pageNext.actionID))
        #expect(texts(in: node).contains("1/1"))
    }

    @Test("G4 审批卡：警示图标头 + 命令/工作目录/会话行 + 两行按钮层级")
    func approvalCardMatchesMockupLayout() throws {
        let approval = ApprovalRequest(
            id: "a-1", kind: .shellCommand, title: "运行 shell 命令",
            detail: "/bin/zsh -lc ls", cwd: "/tmp/lenscrew-demo",
            options: [
                .init(id: "accept", label: "Approve", kind: .allow, scope: .once),
                .init(
                    id: "acceptForSession", label: "Approve for session",
                    kind: .allow, scope: .session
                ),
                .init(id: "decline", label: "Decline", kind: .deny, scope: .once),
            ],
            requestedAtMs: 0
        )
        var cardBudget = GlassLayoutBudget.default
        cardBudget.contentLines = GlassScreenComposer.approvalDetailLines
        // 与 GlassScreenRenderer 同路径：detail 走 textPages 默认档
        let pages = TranscriptPaginator.textPages(approval.detail, budget: cardBudget)
        let node = GlassScreenComposer.approvalCard(
            approval, detailPages: pages, index: 0,
            sessionTitle: "lenscrew-demo", agent: .codex
        )
        // 头部警示图标
        #expect(icons(in: node).contains(.exclamationTriangle))
        // 正文三段：命令（绿 body）→ 工作目录（白 body）→ 会话·agent（meta）
        let rendered = textNodes(in: node)
        let command = try #require(rendered.firstIndex {
            $0.text == "/bin/zsh -lc ls" && $0.style == .body && $0.color == .secondary
        })
        let cwd = try #require(rendered.firstIndex {
            $0.text == "工作目录 /tmp/lenscrew-demo" && $0.style == .body && $0.color == .primary
        })
        let context = try #require(rendered.firstIndex {
            $0.text == "lenscrew-demo · Codex" && $0.style == .meta && $0.color == .secondary
        })
        #expect(command < cwd && cwd < context, "正文顺序应为 命令 → 工作目录 → 会话·agent")
        // 按钮层级：批准=primary 独占首行全宽，其余并排次行
        guard case let .flexBox(_, rootChildren) = node,
              case let .flexBox(footerProps, footerRows) = try #require(rootChildren.last)
        else {
            Issue.record("审批卡缺少按钮 footer")
            return
        }
        #expect(footerProps.direction == .column)
        #expect(footerProps.crossAlignment == .stretch, "首行按钮靠列拉伸占满整宽")
        #expect(
            footerRows.first == .button(
                label: "批准", style: .primary,
                actionID: GlassAction.resolveApproval(optionID: "accept").actionID
            )
        )
        guard case let .flexBox(rowProps, rowChildren) = try #require(footerRows.last) else {
            Issue.record("次级按钮应并排成行")
            return
        }
        #expect(rowProps.direction == .row)
        #expect(
            rowChildren == [
                .button(
                    label: "本会话都批", style: .secondary,
                    actionID: GlassAction.resolveApproval(optionID: "acceptForSession").actionID
                ),
                .button(
                    label: "拒绝", style: .outline,
                    actionID: GlassAction.resolveApproval(optionID: "decline").actionID
                ),
            ]
        )
    }

    @Test("G4 没有 session 档时只有批准+拒绝，按钮不凭空造")
    func approvalButtonsStayOptionDriven() {
        let approval = ApprovalRequest(
            id: "a-2", kind: .shellCommand, title: "运行 shell 命令",
            detail: "ls", cwd: nil,
            options: [
                .init(id: "accept", label: "Approve", kind: .allow, scope: .once),
                .init(id: "decline", label: "Decline", kind: .deny, scope: .once),
            ],
            requestedAtMs: 0
        )
        let node = GlassScreenComposer.approvalCard(
            approval, detailPages: [GlassPage(lines: [])], index: 0
        )
        #expect(buttons(in: node).map(\.label) == ["批准", "拒绝"])
        // 没传会话上下文就不渲染那行 meta
        #expect(!texts(in: node).contains { $0.contains(" · ") && $0.contains("Codex") })
    }
}
