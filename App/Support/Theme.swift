import AgentProtocol
import SwiftUI

/// 设计令牌 —— 与 mockup 的 CSS 变量（--lc-*）一一对应。
/// UI 里不许出现裸颜色字面量：改这里一处，六屏一起变。
enum LC {
    static let bg = Color(hex: 0x000000)
    /// iOS 深色卡片
    static let elev = Color(hex: 0x1C1C1E)
    static let elev2 = Color(hex: 0x2C2C2E)
    static let line = Color.white.opacity(0.09)
    static let text = Color.white
    static let text2 = Color(hex: 0xEBEBF5).opacity(0.62)
    static let text3 = Color(hex: 0xEBEBF5).opacity(0.34)
    /// 系统主行动色
    static let blue = Color(hex: 0x0A84FF)
    static let green = Color(hex: 0x30D158)
    /// 待审批
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    /// 「运行中」的亮橙，与待审批的橙区分明暗
    static let runningOrange = Color(hex: 0xFFB340)
    /// 淡蓝，用于 tinted 按钮文字与「计划中」
    static let lightBlue = Color(hex: 0x6EB4FF)
    /// 眼镜屏的强调绿（mockup 眼镜缩略图用色）
    static let glassGreen = Color(hex: 0x9BE8A8)

    /// agent 身份色只作点缀（小圆点/徽标），不做大面积底色
    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: return Color(hex: 0x19C37D)
        case .claude: return Color(hex: 0xE07B54)
        case .cursor: return Color(hex: 0x9D8CFF)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 文案

func agentLabel(_ agent: AgentKind) -> String {
    switch agent {
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .cursor: return "Cursor"
    }
}

// MARK: - 小部件

/// agent 徽标：身份色圆点 + 名称
struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(LC.agent(agent)).frame(width: 7, height: 7)
            Text(agentLabel(agent))
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(LC.agent(agent))
    }
}

/// 状态 pill 的五种样子，对照 mockup 的 StatusPill
struct PillStyle {
    var text: String
    var color: Color
    var background: Color
    var pulse = false

    static func session(_ status: SessionStatus) -> PillStyle {
        switch status {
        case .running:
            return PillStyle(
                text: "运行中", color: LC.runningOrange,
                background: LC.orange.opacity(0.13), pulse: true
            )
        case .awaitingApproval:
            return PillStyle(
                text: "等你审批", color: LC.orange, background: LC.orange.opacity(0.18)
            )
        case .idle:
            return PillStyle(
                text: "空闲", color: Color(hex: 0xEBEBF5).opacity(0.5), background: LC.elev2
            )
        case .starting:
            return PillStyle(
                text: "启动中", color: LC.lightBlue, background: LC.blue.opacity(0.14)
            )
        case .error:
            return PillStyle(text: "出错", color: LC.red, background: LC.red.opacity(0.14))
        case .ended:
            return PillStyle(text: "已结束", color: LC.text3, background: LC.elev2)
        }
    }

    /// shell / toolCall 块的状态。完成时带退出码（有才显示）。
    static func block(_ status: BlockStatus, exitCode: Int?) -> PillStyle {
        switch status {
        case .pending:
            return PillStyle(
                text: "等待中", color: LC.orange, background: LC.orange.opacity(0.18)
            )
        case .running:
            return PillStyle(
                text: "运行中", color: LC.runningOrange,
                background: LC.orange.opacity(0.13), pulse: true
            )
        case .ok:
            let text = exitCode.map { "完成 · \($0)" } ?? "完成"
            return PillStyle(text: text, color: LC.green, background: LC.green.opacity(0.12))
        case .failed:
            let text = exitCode.map { "失败 · \($0)" } ?? "失败"
            return PillStyle(text: text, color: LC.red, background: LC.red.opacity(0.14))
        case .rejected:
            return PillStyle(text: "已拒绝", color: LC.text3, background: LC.elev2)
        }
    }

    static let applied = PillStyle(
        text: "已应用", color: LC.green, background: LC.green.opacity(0.12)
    )
}

struct StatusPill: View {
    let style: PillStyle

    var body: some View {
        HStack(spacing: 4) {
            if style.pulse {
                PulseDot(color: style.color, size: 5)
            }
            Text(style.text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(style.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(style.background, in: Capsule())
    }
}

/// 呼吸圆点：给「运行中」一点生命迹象
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// 通用 chip（--lc-chip）：胶囊、elev2 底、12pt 文字
struct LCChip<Content: View>: View {
    var fontSize: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(LC.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(LC.elev2, in: Capsule())
    }
}

/// 分组标题（--lc-section-h）
struct SectionHeader: View {
    let title: String
    var titleColor: Color = LC.text2
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(titleColor)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text3)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// 0.5pt 发丝线（--lc-hair）
struct Hairline: View {
    var body: some View {
        LC.line.frame(height: 0.5)
    }
}

/// mockup 的三种按钮底色：primary 蓝实底 / tinted 蓝 16% / plain elev2
enum LCButtonKind {
    case primary, tinted, plain

    var background: Color {
        switch self {
        case .primary: return LC.blue
        case .tinted: return LC.blue.opacity(0.16)
        case .plain: return LC.elev2
        }
    }

    var foreground: Color {
        switch self {
        case .primary: return .white
        case .tinted: return LC.lightBlue
        case .plain: return LC.text
        }
    }
}

struct LCButton: View {
    let title: String
    let kind: LCButtonKind
    var icon: String?
    var minHeight: CGFloat = 50
    var fontSize: CGFloat = 16
    var foregroundOverride: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: fontSize - 2, weight: .bold))
                }
                Text(title)
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foregroundOverride ?? kind.foreground)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(kind.background, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 格式化

/// 相对时间：会话卡与审批卡的 meta 行用
func relativeTime(fromMs ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
    let seconds = Date.now.timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "\(Int(seconds / 3600)) 小时前" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    let days = Int(seconds / 86400)
    if days < 7 { return "\(days) 天前" }
    return date.formatted(.dateTime.month().day())
}

/// token 数量：26_800 → "26.8k"
func formatTokens(_ count: Int) -> String {
    if count < 1000 { return "\(count)" }
    let value = Double(count) / 1000
    return String(format: value < 100 ? "%.1fk" : "%.0fk", value)
}

/// 会话卡预览行：最后一个块的单行摘要。shell 用 mono 呈现，由调用方判断。
func blockPreview(_ block: TranscriptBlock) -> (text: String, mono: Bool) {
    switch block {
    case let .userMessage(_, text, _):
        return ("你：\(text)", false)
    case let .agentMessage(_, text, streaming):
        return (streaming ? "\(text)…" : text, false)
    case let .reasoning(_, _, streaming):
        return (streaming ? "思考中…" : "思考完成", false)
    case let .shellCommand(_, command, _, _, _, status):
        switch status {
        case .pending: return ("$ \(command) — 等待批准", true)
        case .running: return ("$ \(command) — 运行中", true)
        case .failed: return ("$ \(command) — 失败", true)
        case .rejected: return ("$ \(command) — 已拒绝", true)
        case .ok: return ("$ \(command)", true)
        }
    case let .fileChange(_, files, _):
        if files.count == 1, let file = files.first {
            return ("改动 \(fileName(file.path))", false)
        }
        return ("改动 \(files.count) 个文件", false)
    case let .toolCall(_, _, tool, summary, _, _):
        return (summary.isEmpty ? tool : "\(tool) · \(summary)", false)
    case let .plan(_, steps):
        let done = steps.filter { $0.status == .done }.count
        return ("计划 \(done)/\(steps.count) 步", false)
    case let .error(_, message):
        return (message, false)
    }
}

/// 路径最后一段：eg. /tmp/lenscrew-demo/hello.txt → hello.txt
func fileName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
