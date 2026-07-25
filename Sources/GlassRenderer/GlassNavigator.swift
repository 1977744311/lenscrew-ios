import Foundation

public enum GlassScreen: Sendable, Equatable {
    case sessionList
    /// following = true 表示流水增长时自动停在最后一页
    case transcript(sessionID: String, page: Int, following: Bool)
    case blockDetail(sessionID: String, blockID: String, page: Int)
    case approval(sessionID: String, approvalID: String, page: Int)
}

/// 眼镜端导航状态机。
///
/// 眼镜不保存任何状态——手机 app 是唯一事实源（DAT 的明确约定），
/// 所以这台状态机跑在手机上，眼镜只是它的一块投影屏。
public struct GlassNavigator: Sendable, Equatable {
    public private(set) var screen: GlassScreen
    /// 被审批打断前停留的屏；裁决或退出审批后回到这里
    private var suspended: GlassScreen?

    public init(screen: GlassScreen = .sessionList) {
        self.screen = screen
    }

    /// pageCount 是**当前屏**的总页数，只有调用方知道，所以由外部传入。
    public mutating func handle(_ action: GlassAction, pageCount: Int) {
        switch action {
        case let .openSession(sessionID):
            screen = .transcript(sessionID: sessionID, page: 0, following: true)

        case let .openBlock(blockID):
            guard let sessionID = currentSessionID else { return }
            screen = .blockDetail(sessionID: sessionID, blockID: blockID, page: 0)

        case .pageNext:
            movePage(by: 1, pageCount: pageCount)

        case .pagePrevious:
            movePage(by: -1, pageCount: pageCount)

        case .jumpToLatest:
            if case let .transcript(sessionID, _, _) = screen {
                screen = .transcript(
                    sessionID: sessionID, page: max(pageCount - 1, 0), following: true
                )
            }

        case .back:
            goBack()

        case .resolveApproval:
            // 裁决的落地由协调层负责（要发给 bridge），确认后调 dismissApproval
            break
        }
    }

    /// 新审批到达：打断当前屏并记住它。agent 卡在这里等人，别的都不重要了。
    public mutating func presentApproval(sessionID: String, approvalID: String) {
        if case .approval = screen {} else { suspended = screen }
        screen = .approval(sessionID: sessionID, approvalID: approvalID, page: 0)
    }

    /// 审批已了结（可能是在手机上裁的），回到被打断的屏
    public mutating func dismissApproval(_ approvalID: String) {
        guard case let .approval(_, currentID, _) = screen, currentID == approvalID else {
            return
        }
        screen = suspended ?? .sessionList
        suspended = nil
    }

    /// 流水增长。只有跟随模式才自动翻到最后一页——
    /// 用户翻回去看历史时不能被 agent 的新输出拽走。
    public mutating func followLatest(pageCount: Int) {
        guard case let .transcript(sessionID, _, following) = screen, following else {
            return
        }
        screen = .transcript(
            sessionID: sessionID, page: max(pageCount - 1, 0), following: true
        )
    }

    public var currentSessionID: String? {
        switch screen {
        case .sessionList: return nil
        case let .transcript(sessionID, _, _): return sessionID
        case let .blockDetail(sessionID, _, _): return sessionID
        case let .approval(sessionID, _, _): return sessionID
        }
    }

    public var currentPage: Int {
        switch screen {
        case .sessionList: return 0
        case let .transcript(_, page, _): return page
        case let .blockDetail(_, _, page): return page
        case let .approval(_, _, page): return page
        }
    }

    private mutating func movePage(by delta: Int, pageCount: Int) {
        let target = clamp(currentPage + delta, count: pageCount)
        switch screen {
        case .sessionList:
            break
        case let .transcript(sessionID, _, _):
            // 手动翻页即退出跟随，否则下一条输出会把人拽回最新页
            screen = .transcript(
                sessionID: sessionID, page: target,
                following: target >= pageCount - 1
            )
        case let .blockDetail(sessionID, blockID, _):
            screen = .blockDetail(sessionID: sessionID, blockID: blockID, page: target)
        case let .approval(sessionID, approvalID, _):
            screen = .approval(sessionID: sessionID, approvalID: approvalID, page: target)
        }
    }

    private mutating func goBack() {
        switch screen {
        case .sessionList:
            break
        case .transcript:
            screen = .sessionList
        case let .blockDetail(sessionID, _, _):
            screen = .transcript(sessionID: sessionID, page: 0, following: true)
        case .approval:
            // 审批仍然挂着，只是先不看；手机端和会话列表里都还能回到它
            screen = suspended ?? .sessionList
            suspended = nil
        }
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}
