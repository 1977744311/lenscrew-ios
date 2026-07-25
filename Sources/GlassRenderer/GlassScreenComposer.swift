import AgentProtocol
import Foundation

/// 会话列表行的渲染入参。眼镜端不需要完整 AgentSession，
/// 少传一点就少序列化一点——DAT 的整屏内容是走蓝牙的。
public struct GlassSessionSummary: Sendable, Equatable {
    public var id: String
    public var agent: AgentKind
    public var title: String
    public var status: SessionStatus
    public var pendingApprovals: Int

    public init(
        id: String, agent: AgentKind, title: String,
        status: SessionStatus, pendingApprovals: Int
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.status = status
        self.pendingApprovals = pendingApprovals
    }
}

/// 四种眼镜屏的布局生成。全部是纯函数：同样入参必然产出同样的树，
/// 因而可以对 canonicalJSON 做快照测试，不需要眼镜。
public enum GlassScreenComposer {

    /// 审批卡要给工作目录/会话行与两行裁决按钮腾地方，正文预算比普通页少。
    /// mockup 的正文本来就只有三段：命令、工作目录、会话·agent。
    public static let approvalDetailLines = 3

    public static func sessionList(
        _ sessions: [GlassSessionSummary], budget: GlassLayoutBudget = .default
    ) -> GlassNode {
        var rows: [GlassNode] = []
        if sessions.isEmpty {
            rows.append(.text("没有活动会话", style: .body, color: .secondary))
        }
        // 每行占 2 行高。列表不做分页，超出的收进末尾提示——
        // 同时开十几个 agent 会话是极端情况，为它加一套翻页不值当。
        let maxRows = max(budget.contentLines / 2, 1)
        for session in sessions.prefix(maxRows) {
            let badge = session.pendingApprovals > 0
                ? "待审批 \(session.pendingApprovals)"
                : statusText(session.status)
            rows.append(
                .flexBox(
                    FlexBoxProps(
                        direction: .column, gap: 2, padding: 4,
                        actionID: GlassAction.openSession(session.id).actionID
                    ),
                    children: [
                        // mockup 的行标题是 30px，落在 heading(36) 与 body(26) 之间。
                        // 屏顶「会话」已占用 heading 档，行标题取 body 档
                        // 才保得住"页题 > 行题 > meta"的三级层次。
                        .text(
                            GlassText.truncate(session.title, to: budget.bodyChars),
                            style: .body, color: .primary
                        ),
                        .text(
                            "\(agentLabel(session.agent)) · \(badge)",
                            style: .meta, color: .secondary
                        ),
                    ]
                )
            )
        }
        if sessions.count > maxRows {
            rows.append(
                .text("…还有 \(sessions.count - maxRows) 个会话", style: .meta, color: .secondary)
            )
        }
        return screen(
            header: .text("会话", style: .heading, color: .primary),
            content: rows,
            // mockup 底部的白色操作提示；空列表连"点按进入"都无从谈起，不放脚注
            footer: sessions.isEmpty
                ? nil
                : .text("点按会话进入 · 共 \(sessions.count) 个", style: .meta, color: .primary)
        )
    }

    public static func transcriptPage(
        title: String,
        agent: AgentKind,
        status: SessionStatus,
        pages: [GlassPage],
        index: Int,
        following: Bool,
        budget: GlassLayoutBudget = .default
    ) -> GlassNode {
        let clamped = clamp(index, count: pages.count)
        let header = GlassNode.flexBox(
            FlexBoxProps(direction: .column, gap: 1),
            children: [
                .text(
                    GlassText.truncate(title, to: budget.headingChars),
                    style: .heading, color: .primary
                ),
                .text(
                    "\(agentLabel(agent)) · \(statusText(status))"
                        + (following ? " · 跟随" : ""),
                    style: .meta, color: .secondary
                ),
            ]
        )
        return screen(
            header: header,
            content: nodes(for: pages[safe: clamped]?.lines ?? []),
            footer: pageFooter(index: clamped, count: pages.count, showLatest: !following)
        )
    }

    public static func blockDetail(
        title: String, pages: [GlassPage], index: Int,
        budget: GlassLayoutBudget = .default
    ) -> GlassNode {
        let clamped = clamp(index, count: pages.count)
        return screen(
            header: .text(
                GlassText.truncate(detailTitle(title), to: budget.headingChars),
                style: .heading, color: .primary
            ),
            content: nodes(for: pages[safe: clamped]?.lines ?? []),
            footer: pageFooter(index: clamped, count: pages.count, showLatest: false)
        )
    }

    /// 调用方（GlassScreenRenderer）传进来的 title 是 block.kind 的英文标识，
    /// 直接上屏会露出 "shellCommand" 这类代码词。已知标识翻译成中文类别词；
    /// mockup 里"命令 + 状态"那两行头由 detailPages 的首行承担，这里只是类别锚点。
    private static func detailTitle(_ raw: String) -> String {
        switch raw {
        case "shellCommand": return "Shell 命令"
        case "fileChange": return "文件改动"
        case "toolCall": return "工具调用"
        case "plan": return "计划"
        case "error": return "错误"
        case "userMessage", "agentMessage": return "消息"
        case "reasoning": return "思考"
        default: return raw
        }
    }

    /// 审批卡。会打断当前浏览：agent 卡在这里等人，别的都不重要了。
    /// 选项按钮由 adapter 决定（codex 有 approved_for_session，acp 由 agent 动态给），
    /// 所以这里不硬编码「批准/拒绝」两个按钮。
    ///
    /// `sessionTitle` / `agent` 是 mockup 里「lenscrew-demo · Codex」那行上下文；
    /// ApprovalRequest 本身不带会话信息，由调用方另给，缺省不渲染该行。
    public static func approvalCard(
        _ approval: ApprovalRequest,
        detailPages: [GlassPage],
        index: Int,
        sessionTitle: String? = nil,
        agent: AgentKind? = nil,
        budget: GlassLayoutBudget = .default
    ) -> GlassNode {
        let clamped = clamp(index, count: detailPages.count)
        var content = nodes(for: detailPages[safe: clamped]?.lines ?? [])
        // mockup 的正文三段：命令（绿 body，来自 detailPages）→ 工作目录（白 body）
        // → 会话·agent（meta）。后两段是上下文锚点，每一页都带着，
        // 翻页时不丢"正在批谁家的什么"。
        if let cwd = approval.cwd {
            content.append(
                .text(
                    GlassText.truncate("工作目录 \(cwd)", to: budget.bodyChars),
                    style: .body, color: .primary
                )
            )
        }
        let context = [sessionTitle, agent.map(agentLabel)].compactMap { $0 }
        if !context.isEmpty {
            content.append(
                .text(
                    GlassText.truncate(
                        context.joined(separator: " · "), to: budget.metaChars
                    ),
                    style: .meta, color: .secondary
                )
            )
        }
        // 按影响面分两行：allow+once（primary）独占全宽首行，其余选项并排次行。
        // 层级沿用 buttonStyle 的既有弱化策略；集合本身仍完全由 approval.options
        // 驱动——没有的档位不凭空造按钮，多页时翻页钮单独成行不与裁决混排。
        let primaries = approval.options.filter { buttonStyle($0.kind, $0.scope) == .primary }
        let others = approval.options.filter { buttonStyle($0.kind, $0.scope) != .primary }
        var footerRows: [GlassNode] = []
        if detailPages.count > 1 {
            footerRows.append(
                pageFooter(index: clamped, count: detailPages.count, showLatest: false)
            )
        }
        footerRows += primaries.map(approvalButton(for:))
        if !others.isEmpty {
            footerRows.append(
                .flexBox(
                    FlexBoxProps(direction: .row, gap: 6, alignment: .center),
                    children: others.map(approvalButton(for:))
                )
            )
        }
        return screen(
            header: .flexBox(
                FlexBoxProps(direction: .row, gap: 4, crossAlignment: .center),
                children: [
                    .icon(.exclamationTriangle),
                    .text(
                        GlassText.truncate(approval.title, to: budget.headingChars - 3),
                        style: .heading, color: .primary
                    ),
                ]
            ),
            content: content,
            footer: footerRows.isEmpty
                ? nil
                : .flexBox(
                    // crossAlignment 拉伸让首行的 primary 按钮占满整宽（mockup 的全宽「批准」）
                    FlexBoxProps(direction: .column, gap: 6, crossAlignment: .stretch),
                    children: footerRows
                )
        )
    }

    private static func approvalButton(for option: ApprovalOption) -> GlassNode {
        .button(
            label: buttonLabel(kind: option.kind, scope: option.scope),
            style: buttonStyle(option.kind, option.scope),
            actionID: GlassAction.resolveApproval(optionID: option.id).actionID
        )
    }

    // MARK: - 组装

    private static func screen(
        header: GlassNode, content: [GlassNode], footer: GlassNode?
    ) -> GlassNode {
        var children: [GlassNode] = [header]
        children.append(
            .flexBox(FlexBoxProps(direction: .column, gap: 2), children: content)
        )
        if let footer { children.append(footer) }
        return .flexBox(
            FlexBoxProps(direction: .column, gap: 8, crossAlignment: .stretch, padding: 12),
            children: children
        )
    }

    /// 可点的行要包一层 FlexBox：契约里只有 flexBox 和 button 能带 actionID
    private static func nodes(for lines: [GlassLine]) -> [GlassNode] {
        lines.map { line in
            let text = GlassNode.text(line.text, style: line.style, color: line.color)
            guard let actionID = line.actionID else { return text }
            return .flexBox(
                FlexBoxProps(direction: .row, actionID: actionID), children: [text]
            )
        }
    }

    private static func pageFooter(
        index: Int, count: Int, showLatest: Bool
    ) -> GlassNode {
        var children: [GlassNode] = [
            .button(label: "←", style: .outline, actionID: GlassAction.pagePrevious.actionID),
            .text("\(index + 1)/\(max(count, 1))", style: .meta, color: .secondary),
            .button(label: "→", style: .outline, actionID: GlassAction.pageNext.actionID),
        ]
        if showLatest {
            children.append(
                .button(label: "最新", style: .secondary, actionID: GlassAction.jumpToLatest.actionID)
            )
        }
        return .flexBox(
            FlexBoxProps(direction: .row, gap: 8, alignment: .center, crossAlignment: .center),
            children: children
        )
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// 按钮文案由 kind + scope 推导，不用 adapter 给的 label。
    /// 三个运行时的原生文案各不相同（"Allow once" / "总是允许" / "acceptForSession"），
    /// 而在只能 tap 的小屏上，"就这一次"和"永久放行"必须用同一套词区分开。
    private static func buttonLabel(
        kind: ApprovalOptionKind, scope: ApprovalScope
    ) -> String {
        switch (kind, scope) {
        case (.allow, .once): return "批准"
        case (.allow, .session): return "本会话都批"
        case (.allow, .persistent): return "永久批准"
        case (.deny, .once): return "拒绝"
        case (.deny, .session): return "本会话都拒"
        case (.deny, .persistent): return "永久拒绝"
        case (.abort, _): return "中断"
        }
    }

    /// 只有"就这一次"的批准是主按钮。留痕越久的选项越不该被顺手点到。
    private static func buttonStyle(
        _ kind: ApprovalOptionKind, _ scope: ApprovalScope
    ) -> GlassButtonStyle {
        switch (kind, scope) {
        case (.allow, .once): return .primary
        case (.allow, _): return .secondary
        case (.deny, _), (.abort, _): return .outline
        }
    }

    private static func agentLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }

    private static func statusText(_ status: SessionStatus) -> String {
        switch status {
        // mockup 的状态词表把"会话已建、还没跑起来"这一档叫「计划中」
        case .starting: return "计划中"
        case .idle: return "空闲"
        case .running: return "运行中"
        case .awaitingApproval: return "待审批"
        case .error: return "出错"
        case .ended: return "已结束"
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
