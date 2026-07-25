import AgentProtocol
import Testing

@testable import GlassRenderer

@Suite("会话流水分页")
struct TranscriptPaginatorTests {

    private let budget = GlassLayoutBudget.default

    private func message(_ id: String, _ text: String) -> TranscriptBlock {
        .agentMessage(id: id, text: text, streaming: false)
    }

    @Test("每页不超过预算行数")
    func respectsLineBudget() {
        let blocks = (0..<20).map { message("b\($0)", "第 \($0) 条消息，内容不算长。") }
        let pages = TranscriptPaginator.paginate(blocks: blocks, agent: .codex, budget: budget)
        #expect(pages.count > 1)
        #expect(pages.allSatisfy { $0.lines.count <= budget.contentLines })
    }

    /// 这是分页最重要的性质：用户翻回去看历史时，agent 还在输出不能把版重排。
    @Test("末尾追加内容不改动已有的历史页")
    func earlierPagesAreStableUnderAppend() {
        let blocks = (0..<15).map { message("b\($0)", "消息 \($0)") }
        let before = TranscriptPaginator.paginate(
            blocks: blocks, agent: .codex, budget: budget
        )
        let after = TranscriptPaginator.paginate(
            blocks: blocks + [message("new", "新来的一条")], agent: .codex, budget: budget
        )
        #expect(after.count >= before.count)
        for index in 0..<(before.count - 1) {
            #expect(before[index] == after[index], "第 \(index) 页被追加内容改动了")
        }
    }

    @Test("多行片段的标题不会孤零零落在页尾")
    func avoidsOrphanedHeaders() {
        // 精确填到只剩一行：消息片段占 2 行（署名 + 正文），无步骤的计划占 1 行
        var filler: [TranscriptBlock] = []
        var used = 0
        while used + 2 <= budget.contentLines - 1 {
            filler.append(message("f\(used)", "短"))
            used += 2
        }
        while used < budget.contentLines - 1 {
            filler.append(.plan(id: "p\(used)", steps: []))
            used += 1
        }
        let shell = TranscriptBlock.shellCommand(
            id: "s", command: "npm test", cwd: nil, output: "PASS\n",
            exitCode: 0, status: .ok
        )
        let pages = TranscriptPaginator.paginate(
            blocks: filler + [shell], agent: .codex, budget: budget
        )
        #expect(pages.count >= 2)
        // shell 片段整体被推到了下一页，第一页不含它的标题行
        #expect(!(pages[0].lines.contains { $0.text.hasPrefix("$ ") }))
        #expect(pages[1].lines.first?.text.hasPrefix("$ ") == true)
    }

    @Test("流水页只显示 shell 输出的尾部，完整输出走详情页")
    func trimsLongOutputInTranscript() {
        let output = (0..<50).map { "line \($0)" }.joined(separator: "\n")
        let shell = TranscriptBlock.shellCommand(
            id: "s", command: "build", cwd: "/tmp", output: output,
            exitCode: 0, status: .ok
        )
        let transcript = TranscriptPaginator.paginate(
            blocks: [shell], agent: .codex, budget: budget
        )
        let transcriptLines = transcript.flatMap(\.lines)
        #expect(transcriptLines.contains { $0.text == "…" })
        #expect(transcriptLines.count <= 2 + TranscriptPaginator.outputTailLines + 1)

        let detail = TranscriptPaginator.detailPages(
            for: shell, agent: .codex, budget: budget
        )
        let detailLines = detail.flatMap(\.lines)
        #expect(detailLines.contains { $0.text.contains("line 49") })
        #expect(detailLines.contains { $0.text.contains("line 0") })
    }

    @Test("shell、文件改动、工具调用的行可点开详情")
    func marksDrillableLines() {
        let blocks: [TranscriptBlock] = [
            .shellCommand(
                id: "s", command: "ls", cwd: nil, output: "", exitCode: nil, status: .running
            ),
            .fileChange(
                id: "f", files: [.init(path: "src/a.ts", added: 1, removed: 0)], status: .ok
            ),
            .toolCall(
                id: "t", source: nil, tool: "WebSearch", summary: "查文档",
                output: "", status: .ok
            ),
        ]
        let lines = TranscriptPaginator
            .paginate(blocks: blocks, agent: .claude, budget: budget)
            .flatMap(\.lines)
        for id in ["s", "f", "t"] {
            #expect(
                lines.contains { $0.actionID == GlassAction.openBlock(id).actionID },
                "block \(id) 没有可点开详情的行"
            )
        }
    }

    @Test("流式消息带光标标记")
    func marksStreamingMessage() {
        let pages = TranscriptPaginator.paginate(
            blocks: [.agentMessage(id: "b", text: "正在想", streaming: true)],
            agent: .cursor, budget: budget
        )
        #expect(pages.flatMap(\.lines).contains { $0.text.hasSuffix("▍") })
    }

    @Test("空流水也产出一页，渲染层不必处理空数组")
    func emptyTranscriptStillYieldsOnePage() {
        let pages = TranscriptPaginator.paginate(blocks: [], agent: .codex, budget: budget)
        #expect(pages.count == 1)
        #expect(pages[0].lines.isEmpty)
    }
}
