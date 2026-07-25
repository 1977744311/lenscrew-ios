import AgentProtocol
import GlassRenderer

public struct GlassRenderResult: Sendable, Equatable {
    public var node: GlassNode
    /// 当前屏的总页数；导航状态机夹页码要用
    public var pageCount: Int

    public init(node: GlassNode, pageCount: Int) {
        self.node = node
        self.pageCount = pageCount
    }
}

/// 会话状态 + 导航位置 → 一屏布局树。
///
/// 纯函数，所以整块眼镜端 UI 都能在单测里断言，不需要眼镜、不需要 SDK。
/// 找不到目标（会话已关、审批已被手机裁掉）一律退回会话列表，
/// 而不是渲染一屏空白让人以为设备坏了。
public enum GlassScreenRenderer {

    public static func render(
        screen: GlassScreen,
        store: CrewStore,
        budget: GlassLayoutBudget = .default
    ) -> GlassRenderResult {
        switch screen {
        case .sessionList:
            return sessionList(store: store, budget: budget)

        case let .transcript(sessionID, page, following):
            guard let state = store.sessions[sessionID] else {
                return sessionList(store: store, budget: budget)
            }
            let pages = TranscriptPaginator.paginate(
                blocks: state.blocks, agent: state.session.agent, budget: budget
            )
            return GlassRenderResult(
                node: GlassScreenComposer.transcriptPage(
                    title: state.session.title,
                    agent: state.session.agent,
                    status: state.session.status,
                    pages: pages,
                    index: page,
                    following: following,
                    budget: budget
                ),
                pageCount: pages.count
            )

        case let .blockDetail(sessionID, blockID, page):
            guard let state = store.sessions[sessionID],
                  let block = state.blocks.first(where: { $0.id == blockID })
            else {
                return sessionList(store: store, budget: budget)
            }
            let pages = TranscriptPaginator.detailPages(
                for: block, agent: state.session.agent, budget: budget
            )
            return GlassRenderResult(
                node: GlassScreenComposer.blockDetail(
                    title: block.kind, pages: pages, index: page, budget: budget
                ),
                pageCount: pages.count
            )

        case let .approval(sessionID, approvalID, page):
            guard let state = store.sessions[sessionID],
                  let approval = state.pendingApprovals.first(where: { $0.id == approvalID })
            else {
                return sessionList(store: store, budget: budget)
            }
            // 审批卡要给选项按钮腾出高度，正文预算比普通页小
            var cardBudget = budget
            cardBudget.contentLines = GlassScreenComposer.approvalDetailLines
            let pages = TranscriptPaginator.textPages(approval.detail, budget: cardBudget)
            return GlassRenderResult(
                node: GlassScreenComposer.approvalCard(
                    approval, detailPages: pages, index: page,
                    // 会话与 agent 是审批的上下文锚点：眼镜上批的是"谁家的什么"
                    sessionTitle: state.session.title,
                    agent: state.session.agent,
                    budget: budget
                ),
                pageCount: pages.count
            )
        }
    }

    private static func sessionList(
        store: CrewStore, budget: GlassLayoutBudget
    ) -> GlassRenderResult {
        let summaries = store.orderedSessions.map { state in
            GlassSessionSummary(
                id: state.session.id,
                agent: state.session.agent,
                title: state.session.title,
                status: state.session.status,
                pendingApprovals: state.pendingApprovals.count
            )
        }
        return GlassRenderResult(
            node: GlassScreenComposer.sessionList(summaries, budget: budget),
            pageCount: 1
        )
    }
}
