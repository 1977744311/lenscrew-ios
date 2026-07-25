import AgentProtocol
import Foundation

public struct GlassPage: Sendable, Equatable {
    public var lines: [GlassLine]
    public init(lines: [GlassLine]) { self.lines = lines }
}

/// 会话流水 → 眼镜屏页序列。
///
/// 眼镜端要做的是"完整会话浏览"，但屏幕只有 600×600、输入只有 tap、
/// 而且 DAT 既不给滚动回调也不给滚动位置。所以不能依赖滚动，只能把流水
/// 切成确定的页序列，让用户用翻页按钮走。
///
/// **稳定性**是这里最重要的性质：从头贪心装页，所以在末尾追加内容只会影响最后一两页，
/// 用户翻回去看的历史页不会因为 agent 还在输出而重新排版跳走。
/// 流式增量只修改最后一个 block，这个前提成立。
public enum TranscriptPaginator {

    /// 流水页里每个 shell 命令最多显示的输出行数；完整输出走 `detailPages`。
    /// 不限制的话一条 npm install 就能吃掉几十页。
    public static let outputTailLines = 4

    public static func paginate(
        blocks: [TranscriptBlock],
        agent: AgentKind,
        budget: GlassLayoutBudget = .default
    ) -> [GlassPage] {
        let fragments = blocks.map { fragment(for: $0, agent: agent, budget: budget) }
        return pack(fragments, budget: budget)
    }

    /// 裸文本分页。审批的 detail 是一段自由文本（命令原文、diff 摘要），
    /// 不属于任何流水块，但同样可能长到一屏放不下。
    /// 默认档取 body：mockup 审批卡上的命令是绿色 body，不是小字 meta。
    public static func textPages(
        _ text: String,
        style: GlassTextStyle = .body,
        budget: GlassLayoutBudget = .default
    ) -> [GlassPage] {
        let lines = GlassText.wrap(text, width: budget.chars(for: style))
            .map { GlassLine($0, style: style, color: .secondary) }
        return pack([lines], budget: budget)
    }

    /// 单个 block 的完整详情分页（shell 命令的全量输出、错误全文等）
    public static func detailPages(
        for block: TranscriptBlock,
        agent: AgentKind,
        budget: GlassLayoutBudget = .default
    ) -> [GlassPage] {
        let lines = detailLines(for: block, agent: agent, budget: budget)
        return pack([lines], budget: budget)
    }

    // MARK: - 装页

    /// 贪心装页 + 孤行控制：一个多行片段的标题行不允许单独落在页尾，
    /// 9 行的屏幕上出现悬空标题会让人以为内容丢了。
    private static func pack(
        _ fragments: [[GlassLine]], budget: GlassLayoutBudget
    ) -> [GlassPage] {
        var pages: [GlassPage] = []
        var current: [GlassLine] = []

        func flush() {
            if !current.isEmpty {
                pages.append(GlassPage(lines: current))
                current = []
            }
        }

        for fragment in fragments {
            guard !fragment.isEmpty else { continue }
            let remaining = budget.contentLines - current.count
            if fragment.count > 1, remaining == 1 {
                flush()
            }
            for line in fragment {
                if current.count == budget.contentLines { flush() }
                current.append(line)
            }
        }
        flush()
        return pages.isEmpty ? [GlassPage(lines: [])] : pages
    }

    // MARK: - block → 行

    private static func fragment(
        for block: TranscriptBlock, agent: AgentKind, budget: GlassLayoutBudget
    ) -> [GlassLine] {
        switch block {
        case let .userMessage(_, text, imageCount):
            var lines = [GlassLine("你", style: .meta, color: .secondary)]
            lines += wrapped(text, style: .body, budget: budget)
            if imageCount > 0 {
                lines.append(
                    GlassLine("附图 \(imageCount) 张", style: .meta, color: .secondary)
                )
            }
            return lines

        case let .agentMessage(_, text, streaming):
            var lines = [GlassLine(agentLabel(agent), style: .meta, color: .secondary)]
            lines += wrapped(streaming ? text + "▍" : text, style: .body, budget: budget)
            return lines

        case let .reasoning(_, text, streaming):
            var lines = [
                GlassLine(streaming ? "思考中…" : "思考", style: .meta, color: .secondary)
            ]
            lines += wrapped(text, style: .meta, budget: budget).map {
                GlassLine($0.text, style: .meta, color: .secondary)
            }
            return lines

        case let .shellCommand(id, command, _, output, exitCode, status):
            let action = GlassAction.openBlock(id).actionID
            // mockup 把 shell 收成一行绿色 body「$ ls -la · 完成 0」：
            // 命令与结果同行；DAT 没有等宽字体，mono 语义靠 $ 前缀
            // 与紧凑退出码的文案格式贴近。
            let suffix = " · " + shellCompactStatus(status: status, exitCode: exitCode)
            var lines = [
                GlassLine(
                    "$ " + GlassText.truncate(
                        firstLine(command),
                        to: budget.bodyChars - GlassText.width("$ ") - GlassText.width(suffix)
                    ) + suffix,
                    style: .body, color: .secondary, actionID: action
                )
            ]
            lines += tail(of: output, limit: outputTailLines, budget: budget)
                .map { GlassLine($0, style: .meta, color: .secondary, actionID: action) }
            return lines

        case let .fileChange(id, files, status):
            let action = GlassAction.openBlock(id).actionID
            // mockup 把单文件改动收成一行白色 body「hello.txt +1 −0 · 已应用」；
            // 多文件退化为同格式的汇总行 + 文件明细。
            if files.count == 1, let file = files.first {
                let suffix = diffStat(file) + " · " + fileStatusText(status)
                return [
                    GlassLine(
                        GlassText.truncate(
                            lastComponent(file.path),
                            to: budget.bodyChars - GlassText.width(suffix)
                        ) + suffix,
                        style: .body, actionID: action
                    )
                ]
            }
            var lines = [
                GlassLine(
                    "改动 \(files.count) 个文件 · \(fileStatusText(status))",
                    style: .body, actionID: action
                )
            ]
            for file in files.prefix(3) {
                let stat = diffStat(file)
                lines.append(
                    GlassLine(
                        GlassText.truncate(
                            lastComponent(file.path),
                            to: budget.metaChars - GlassText.width(stat) - 1
                        ) + stat,
                        style: .meta, color: .secondary, actionID: action
                    )
                )
            }
            if files.count > 3 {
                lines.append(
                    GlassLine(
                        "…还有 \(files.count - 3) 个", style: .meta,
                        color: .secondary, actionID: action
                    )
                )
            }
            return lines

        case let .toolCall(id, source, tool, summary, _, status):
            let action = GlassAction.openBlock(id).actionID
            let title = source.map { "\($0) · \(tool)" } ?? tool
            var lines = [
                GlassLine(
                    GlassText.truncate(title, to: budget.headingChars),
                    style: .heading, actionID: action
                ),
                GlassLine(statusText(status), style: .meta, color: .secondary, actionID: action),
            ]
            if !summary.isEmpty {
                lines += wrapped(summary, style: .meta, budget: budget).prefix(2).map {
                    GlassLine($0.text, style: .meta, color: .secondary, actionID: action)
                }
            }
            return lines

        case let .plan(_, steps):
            var lines = [GlassLine("计划", style: .heading)]
            for step in steps {
                lines += wrapped(
                    "\(planMarker(step.status)) \(step.text)", style: .body, budget: budget
                )
            }
            return lines

        case let .error(id, message):
            let action = GlassAction.openBlock(id).actionID
            var lines = [GlassLine("错误", style: .heading, actionID: action)]
            lines += wrapped(message, style: .body, budget: budget).prefix(3).map {
                GlassLine($0.text, style: .body, actionID: action)
            }
            return lines
        }
    }

    private static func detailLines(
        for block: TranscriptBlock, agent: AgentKind, budget: GlassLayoutBudget
    ) -> [GlassLine] {
        switch block {
        case let .shellCommand(_, command, cwd, output, exitCode, status):
            // mockup 块详情的头：「$ 命令」heading + 「完成 · 退出码 0」meta。
            // 输出行升为白色 body——它是这一屏的正文主角，不再当次要信息压灰。
            var lines = wrapped("$ " + command, style: .heading, budget: budget)
            lines.append(
                GlassLine(
                    shellStatusText(status: status, exitCode: exitCode),
                    style: .meta, color: .secondary
                )
            )
            if let cwd {
                lines.append(GlassLine(cwd, style: .meta, color: .secondary))
            }
            lines += wrapped(output, style: .body, budget: budget)
            return lines

        case let .fileChange(_, files, status):
            var lines = [GlassLine("改动 · \(fileStatusText(status))", style: .heading)]
            for file in files {
                lines.append(GlassLine(file.path, style: .meta, color: .secondary))
                let stat = diffStat(file)
                if !stat.isEmpty {
                    lines.append(
                        GlassLine(
                            stat.trimmingCharacters(in: .whitespaces),
                            style: .meta, color: .secondary
                        )
                    )
                }
            }
            return lines

        case let .toolCall(_, source, tool, summary, output, status):
            var lines = [
                GlassLine(source.map { "\($0) · \(tool)" } ?? tool, style: .heading),
                GlassLine(statusText(status), style: .meta, color: .secondary),
            ]
            lines += wrapped(summary, style: .body, budget: budget)
            lines += wrapped(output, style: .meta, budget: budget).map {
                GlassLine($0.text, style: .meta, color: .secondary)
            }
            return lines

        default:
            return fragment(for: block, agent: agent, budget: budget)
        }
    }

    // MARK: - 小工具

    private static func wrapped(
        _ text: String, style: GlassTextStyle, budget: GlassLayoutBudget
    ) -> [GlassLine] {
        GlassText.wrap(text, width: budget.chars(for: style))
            .map { GlassLine($0, style: style) }
    }

    private static func tail(
        of output: String, limit: Int, budget: GlassLayoutBudget
    ) -> [String] {
        guard !output.isEmpty else { return [] }
        let wrapped = GlassText.wrap(output, width: budget.metaChars)
        guard wrapped.count > limit else { return wrapped }
        return ["…"] + wrapped.suffix(limit)
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// 行数增删不是每个运行时都给得出。给不出时留空，
    /// 而不是显示 "+0 −0" —— 那会被读成"改了但没变化"。
    private static func diffStat(_ file: FileChangeSummary) -> String {
        switch (file.added, file.removed) {
        case let (added?, removed?): return " +\(added) −\(removed)"
        case let (added?, nil): return " +\(added)"
        case let (nil, removed?): return " −\(removed)"
        case (nil, nil): return ""
        }
    }

    private static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private static func agentLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }

    private static func statusText(_ status: BlockStatus) -> String {
        switch status {
        case .pending: return "等待中"
        case .running: return "运行中"
        case .ok: return "完成"
        case .failed: return "失败"
        case .rejected: return "已拒绝"
        }
    }

    private static func shellStatusText(status: BlockStatus, exitCode: Int?) -> String {
        guard let exitCode else { return statusText(status) }
        return "\(statusText(status)) · 退出码 \(exitCode)"
    }

    /// 流水页的紧凑形态「完成 0」；块详情才用全称「完成 · 退出码 0」——
    /// 摘要行还要塞下命令本身，字面越短留给命令的宽度越多。
    private static func shellCompactStatus(status: BlockStatus, exitCode: Int?) -> String {
        guard let exitCode else { return statusText(status) }
        return "\(statusText(status)) \(exitCode)"
    }

    /// 文件改动的状态词面向"落没落盘"：ok=已应用、pending=待应用（mockup 用词），
    /// 其余档沿用通用状态词。
    private static func fileStatusText(_ status: BlockStatus) -> String {
        switch status {
        case .ok: return "已应用"
        case .pending: return "待应用"
        default: return statusText(status)
        }
    }

    private static func planMarker(_ status: PlanStep.Status) -> String {
        switch status {
        case .pending: return "·"
        case .running: return "▸"
        case .done: return "✓"
        }
    }
}
