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

    /// 审批卡要给选项按钮腾地方，正文预算比普通页少
    public static let approvalDetailLines = 5

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
                        .text(
                            GlassText.truncate(session.title, to: budget.headingChars),
                            style: .heading, color: .primary
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
            footer: nil
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
                GlassText.truncate(title, to: budget.headingChars),
                style: .heading, color: .primary
            ),
            content: nodes(for: pages[safe: clamped]?.lines ?? []),
            footer: pageFooter(index: clamped, count: pages.count, showLatest: false)
        )
    }

    /// 审批卡。会打断当前浏览：agent 卡在这里等人，别的都不重要了。
    /// 选项按钮由 adapter 决定（codex 有 approved_for_session，acp 由 agent 动态给），
    /// 所以这里不硬编码「批准/拒绝」两个按钮。
    public static func approvalCard(
        _ approval: ApprovalRequest,
        detailPages: [GlassPage],
        index: Int,
        budget: GlassLayoutBudget = .default
    ) -> GlassNode {
        let clamped = clamp(index, count: detailPages.count)
        var content = nodes(for: detailPages[safe: clamped]?.lines ?? [])
        if detailPages.count > 1 {
            content.append(
                .text("\(clamped + 1)/\(detailPages.count)", style: .meta, color: .secondary)
            )
        }
        let buttons: [GlassNode] = approval.options.map { option in
            .button(
                label: buttonLabel(kind: option.kind, scope: option.scope),
                style: buttonStyle(option.kind, option.scope),
                actionID: GlassAction.resolveApproval(optionID: option.id).actionID
            )
        }
        var footer: [GlassNode] = buttons
        if detailPages.count > 1 {
            footer.insert(
                .button(label: "←", style: .outline, actionID: GlassAction.pagePrevious.actionID),
                at: 0
            )
            footer.append(
                .button(label: "→", style: .outline, actionID: GlassAction.pageNext.actionID)
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
            footer: .flexBox(
                FlexBoxProps(direction: .row, gap: 6, alignment: .center),
                children: footer
            )
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
        case .starting: return "启动中"
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
