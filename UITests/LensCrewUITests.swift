import XCTest

/// XCUITest 走 `-uitest-fixture` 启动参数：App 内 CrewViewModel 换上内存脚本连接
/// （1 个会话 + 1 条 shell 审批 + 几个块）并预置一台假 active 主机，
/// 全程不碰网络与 Keychain，见 App/Support/UITestFixture.swift。
/// 断言一律用 accessibilityIdentifier，文案断言只针对夹具脚本里的确定值。
final class LensCrewUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fixture"]
        app.launch()
        return app
    }

    /// SwiftUI 容器上的 identifier 元素类型不稳定（other/button/scrollView 都可能），
    /// 统一按任意类型查，firstMatch 容忍层级里同 id 的重复投影
    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitForDisappearance(
        of element: XCUIElement, timeout: TimeInterval = 10, _ message: String
    ) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message)
    }

    // MARK: - 用例

    @MainActor
    func testCommandDeckShowsSessionAndApproval_thenAllowOnceDismissesSheet() {
        let app = launchApp()

        // 指挥台：会话卡与「等你审批」区都在
        XCTAssertTrue(
            element(app, "home.approvalCard").waitForExistence(timeout: 15),
            "夹具审批卡没有出现在指挥台"
        )
        XCTAssertTrue(element(app, "home.approvalsHeader").exists, "「等你审批」分区头缺席")
        XCTAssertTrue(element(app, "home.sessionCard").exists, "夹具会话卡缺席")

        // 点审批卡的「查看上下文」进会话页，再点底部审批行弹审批 sheet
        element(app, "home.approval.context").tap()
        XCTAssertTrue(
            element(app, "session.approvalRow").waitForExistence(timeout: 10),
            "会话页底部没有「等你审批」入口行"
        )
        element(app, "session.approvalRow").tap()

        // 审批 sheet：人话标题 + 命令正文
        let title = element(app, "approval.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "审批 sheet 没弹出")
        XCTAssertEqual(title.label, "运行 shell 命令")
        XCTAssertTrue(
            element(app, "approval.detail").staticTexts["npm test"].exists,
            "sheet 正文没展示待批命令"
        )

        // 允许一次 → 夹具回 approvalSettled → sheet 收起、审批入口行撤下
        element(app, "approval.allowOnce").tap()
        waitForDisappearance(of: element(app, "approval.title"), "裁决后审批 sheet 没收起")
        waitForDisappearance(
            of: element(app, "session.approvalRow"), "审批结清后入口行没撤下"
        )
    }

    @MainActor
    func testSettingsShowsAllFourSections() {
        let app = launchApp()
        XCTAssertTrue(element(app, "tab.settings").waitForExistence(timeout: 15))
        element(app, "tab.settings").tap()

        for section in ["电脑", "安全", "通知", "关于"] {
            XCTAssertTrue(
                element(app, "settings.section.\(section)").waitForExistence(timeout: 10),
                "设置页缺「\(section)」分组"
            )
        }
    }

    @MainActor
    func testNewSessionSheetListsThreeAgentsAndStartButton() {
        let app = launchApp()
        XCTAssertTrue(element(app, "dock.newSession").waitForExistence(timeout: 15))
        element(app, "dock.newSession").tap()

        for agent in ["codex", "claude", "cursor"] {
            XCTAssertTrue(
                element(app, "newSession.agent.\(agent)").waitForExistence(timeout: 10),
                "新会话 sheet 缺 \(agent) 行"
            )
        }
        XCTAssertTrue(element(app, "newSession.start").exists, "「开始会话」按钮缺席")

        app.buttons["取消"].firstMatch.tap()
        waitForDisappearance(of: element(app, "newSession.start"), "新会话 sheet 没收起")
    }

    @MainActor
    func testGlassesTabShowsSquarePreview() {
        let app = launchApp()
        XCTAssertTrue(element(app, "tab.glasses").waitForExistence(timeout: 15))
        element(app, "tab.glasses").tap()

        XCTAssertTrue(
            element(app, "glasses.preview").waitForExistence(timeout: 10),
            "眼镜页没有画面预览区"
        )
        // 600×600 是 DAT 硬约束，约束 chip 必须在场
        XCTAssertTrue(app.staticTexts["600 × 600"].firstMatch.exists)
    }

    @MainActor
    func testGitPanelShowsStatusAndOpensDiff() {
        let app = launchApp()

        // 进会话页 → 导航头的 git 入口
        XCTAssertTrue(
            element(app, "home.approvalCard").waitForExistence(timeout: 15),
            "夹具审批卡没有出现在指挥台"
        )
        element(app, "home.approval.context").tap()
        XCTAssertTrue(
            element(app, "session.gitPanel").waitForExistence(timeout: 10),
            "会话页导航头缺 git 面板入口"
        )
        element(app, "session.gitPanel").tap()

        // 面板：分支名、暂存/工作区文件行都来自夹具脚本
        let branch = element(app, "git.branch")
        XCTAssertTrue(branch.waitForExistence(timeout: 10), "git 面板没显示分支")
        XCTAssertEqual(branch.label, "main")
        XCTAssertTrue(
            element(app, "git.file.Sources/App/Login.swift").waitForExistence(timeout: 10),
            "已暂存文件行缺席"
        )
        XCTAssertTrue(element(app, "git.file.README.md").exists, "工作区文件行缺席")
        // 大改动场景的第一需求是体量概览：文件行必须带增删行数
        XCTAssertTrue(app.staticTexts["+128 −43"].firstMatch.exists, "文件行没显示增删行数")
        XCTAssertTrue(element(app, "git.commit").exists, "提交按钮缺席")

        // 点工作区文件行 → diff sheet 展示夹具 diff 的内容
        element(app, "git.file.README.md").tap()
        XCTAssertTrue(
            app.staticTexts["+new line"].firstMatch.waitForExistence(timeout: 10),
            "diff sheet 没展示新增行"
        )
    }
}
