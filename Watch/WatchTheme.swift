import AgentProtocol
import SwiftUI

/// 手表端设计令牌：色值与手机 App/Support/Theme.swift 的 LC 同源（mockup 的 --lc-*），
/// 尺寸按手表 mockup 的物理像素 ÷2 取 pt。手表 target 不包含手机 UI 源码，
/// 这里只复刻腕上用得到的最小子集，两边各编各的。
enum LCW {
    static let elev = Color(hex: 0x1C1C1E)
    static let elev2 = Color(hex: 0x2C2C2E)
    static let line = Color.white.opacity(0.09)
    static let text = Color.white
    static let text2 = Color(hex: 0xEBEBF5).opacity(0.62)
    static let text3 = Color(hex: 0xEBEBF5).opacity(0.34)
    static let blue = Color(hex: 0x0A84FF)
    static let lightBlue = Color(hex: 0x6EB4FF)
    static let green = Color(hex: 0x30D158)
    static let orange = Color(hex: 0xFF9F0A)
    static let runningOrange = Color(hex: 0xFFB340)
    static let red = Color(hex: 0xFF453A)

    /// agent 身份色只作点缀（小圆点），不做大面积底色
    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: Color(hex: 0x19C37D)
        case .claude: Color(hex: 0xE07B54)
        case .cursor: Color(hex: 0x9D8CFF)
        }
    }
}

extension Color {
    /// 与手机 Theme.swift 的同名扩展等价（watch target 单独一份）
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

func watchAgentLabel(_ agent: AgentKind) -> String {
    switch agent {
    case .codex: "Codex"
    case .claude: "Claude"
    case .cursor: "Cursor"
    }
}

/// 会话状态 → 文案与颜色，对齐手机 PillStyle.session 的口径
func watchStatus(_ status: SessionStatus) -> (text: String, color: Color) {
    switch status {
    case .running: ("运行中", LCW.runningOrange)
    case .awaitingApproval: ("等你审批", LCW.orange)
    case .idle: ("空闲", Color(hex: 0xEBEBF5).opacity(0.5))
    case .starting: ("启动中", LCW.lightBlue)
    case .error: ("出错", LCW.red)
    case .ended: ("已结束", LCW.text3)
    }
}

/// 相对时间：与手机 Theme.swift 的 relativeTime 等价
func watchRelativeTime(fromMs ms: Int64) -> String {
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

/// agent 身份色小圆点
struct WatchAgentDot: View {
    let agent: AgentKind

    var body: some View {
        Circle().fill(LCW.agent(agent)).frame(width: 5, height: 5)
    }
}

/// 全宽胶囊按钮，四种强弱对应 mockup 的 lc-btn-*：
/// primary 蓝实底 / tinted 蓝 16% / plain elev2 / destructive 红 16%
struct WatchCapsuleButton: View {
    enum Kind {
        case primary, tinted, plain, destructive

        var background: Color {
            switch self {
            case .primary: LCW.blue
            case .tinted: LCW.blue.opacity(0.16)
            case .plain: LCW.elev2
            case .destructive: LCW.red.opacity(0.16)
            }
        }

        var foreground: Color {
            switch self {
            case .primary: .white
            case .tinted: LCW.lightBlue
            case .plain: LCW.text
            case .destructive: LCW.red
            }
        }
    }

    let title: String
    let kind: Kind
    var icon: String?
    var minHeight: CGFloat = 33
    var fontSize: CGFloat = 11.5
    var foregroundOverride: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: fontSize - 1, weight: .bold))
                }
                Text(title)
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foregroundOverride ?? kind.foreground)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(kind.background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
