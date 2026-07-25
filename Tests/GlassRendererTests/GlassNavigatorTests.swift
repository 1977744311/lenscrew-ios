import Testing

@testable import GlassRenderer

@Suite("眼镜端导航")
struct GlassNavigatorTests {

    @Test("动作 ID 编解码往返，负载里带冒号也安全")
    func roundTripsActionIDs() {
        let actions: [GlassAction] = [
            .openSession("s:1"), .openBlock("b:2"), .pageNext, .pagePrevious,
            .jumpToLatest, .back, .resolveApproval(optionID: "approved_for_session"),
        ]
        for action in actions {
            #expect(GlassAction(actionID: action.actionID) == action)
        }
        #expect(GlassAction(actionID: "garbage") == nil)
        #expect(GlassAction(actionID: "session:") == nil)
    }

    @Test("翻到非最后一页即退出跟随，翻回最后一页恢复")
    func manualPagingTogglesFollow() {
        var navigator = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 4, following: true)
        )
        navigator.handle(.pagePrevious, pageCount: 5)
        #expect(navigator.screen == .transcript(sessionID: "s", page: 3, following: false))

        navigator.handle(.pageNext, pageCount: 5)
        #expect(navigator.screen == .transcript(sessionID: "s", page: 4, following: true))
    }

    @Test("跟随模式下新内容自动翻到最新页，非跟随时原地不动")
    func followsLatestOnlyWhenFollowing() {
        var following = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 2, following: true)
        )
        following.followLatest(pageCount: 6)
        #expect(following.screen == .transcript(sessionID: "s", page: 5, following: true))

        var browsing = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 2, following: false)
        )
        browsing.followLatest(pageCount: 6)
        #expect(browsing.screen == .transcript(sessionID: "s", page: 2, following: false))
    }

    @Test("审批打断当前屏，裁决后原样回去")
    func approvalPreemptsAndRestores() {
        var navigator = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 3, following: false)
        )
        navigator.presentApproval(sessionID: "s", approvalID: "a-1")
        #expect(navigator.screen == .approval(sessionID: "s", approvalID: "a-1", page: 0))

        navigator.dismissApproval("a-1")
        #expect(navigator.screen == .transcript(sessionID: "s", page: 3, following: false))
    }

    @Test("裁决别的审批不会误关当前这张卡")
    func ignoresUnrelatedApprovalDismissal() {
        var navigator = GlassNavigator(screen: .sessionList)
        navigator.presentApproval(sessionID: "s", approvalID: "a-1")
        navigator.dismissApproval("a-2")
        #expect(navigator.screen == .approval(sessionID: "s", approvalID: "a-1", page: 0))
    }

    @Test("连续两个审批不会把第一张卡记成待恢复的屏")
    func stacksApprovalsWithoutLosingOrigin() {
        var navigator = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 1, following: true)
        )
        navigator.presentApproval(sessionID: "s", approvalID: "a-1")
        navigator.presentApproval(sessionID: "s", approvalID: "a-2")
        navigator.dismissApproval("a-2")
        #expect(navigator.screen == .transcript(sessionID: "s", page: 1, following: true))
    }

    @Test("返回按层级逐级退，列表页是根")
    func backWalksUpTheHierarchy() {
        var navigator = GlassNavigator(
            screen: .blockDetail(sessionID: "s", blockID: "b", page: 2)
        )
        navigator.handle(.back, pageCount: 3)
        #expect(navigator.screen == .transcript(sessionID: "s", page: 0, following: true))

        navigator.handle(.back, pageCount: 1)
        #expect(navigator.screen == .sessionList)

        navigator.handle(.back, pageCount: 1)
        #expect(navigator.screen == .sessionList)
    }

    @Test("页码越界被夹住，不会翻出空白屏")
    func clampsPageIndex() {
        var navigator = GlassNavigator(
            screen: .transcript(sessionID: "s", page: 0, following: false)
        )
        navigator.handle(.pagePrevious, pageCount: 3)
        #expect(navigator.currentPage == 0)

        navigator.handle(.pageNext, pageCount: 3)
        navigator.handle(.pageNext, pageCount: 3)
        navigator.handle(.pageNext, pageCount: 3)
        #expect(navigator.currentPage == 2)
    }
}
