import Foundation

/// 眼镜屏排版预算。
///
/// DAT 0.8.0 不暴露任何字体度量：文字只有 heading/body/meta 三档、没有字号数值、
/// 没有测量 API。所以分页只能按字符宽度估算，这些初值是照 600×600 与三档字号推的，
/// **必须真机校准**；校准前分页结果只保证确定、不保证不溢出。
/// 溢出的后果是 DAT 自己垂直滚动，而 SDK 既无滚动回调也无位置查询——
/// 这正是宁可保守分页也不依赖滚动的原因。
public struct GlassLayoutBudget: Sendable, Equatable {
    /// 一屏正文行数，已扣掉页眉与页脚导航
    public var contentLines: Int
    public var headingChars: Int
    public var bodyChars: Int
    public var metaChars: Int

    public init(contentLines: Int, headingChars: Int, bodyChars: Int, metaChars: Int) {
        self.contentLines = contentLines
        self.headingChars = headingChars
        self.bodyChars = bodyChars
        self.metaChars = metaChars
    }

    public func chars(for style: GlassTextStyle) -> Int {
        switch style {
        case .heading: return headingChars
        case .body: return bodyChars
        case .meta: return metaChars
        }
    }

    /// 真机校准前的保守初值
    public static let `default` = GlassLayoutBudget(
        contentLines: 9, headingChars: 22, bodyChars: 30, metaChars: 38
    )
}

/// 已完成换行的一行，渲染时一对一映射到一个 DAT Text 组件
public struct GlassLine: Sendable, Equatable {
    public var text: String
    public var style: GlassTextStyle
    public var color: GlassTextColor
    /// 点这一行触发的动作；nil 表示不可点
    public var actionID: String?

    public init(
        _ text: String, style: GlassTextStyle = .body,
        color: GlassTextColor = .primary, actionID: String? = nil
    ) {
        self.text = text
        self.style = style
        self.color = color
        self.actionID = actionID
    }
}

public enum GlassText {
    /// 近似显示宽度：CJK、全角标点、emoji 记 2 格，其余记 1 格。
    /// 中英混排在 600×600 上差一格就会溢出一行，所以不能简单用 count。
    public static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
    }

    private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x1100...0x115F,        // 韩文字母
             0x2E80...0x303E,        // CJK 部首、假名标点
             0x3041...0x33FF,        // 假名、注音、CJK 兼容
             0x3400...0x4DBF,        // CJK 扩展 A
             0x4E00...0x9FFF,        // CJK 统一表意
             0xA000...0xA4CF,        // 彝文
             0xAC00...0xD7A3,        // 韩文音节
             0xF900...0xFAFF,        // CJK 兼容表意
             0xFE30...0xFE6F,        // CJK 兼容形式
             0xFF00...0xFF60,        // 全角形式
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF,      // emoji
             0x20000...0x3FFFD:      // CJK 扩展 B 及以后
            return 2
        default:
            return 1
        }
    }

    /// 按显示宽度贪心折行。英文在空格处断，中文任意处断，
    /// 单个超宽词强制切开而不是任其溢出。
    public static func wrap(_ text: String, width limit: Int) -> [String] {
        guard limit > 0 else { return [text] }
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let segment = String(rawLine)
            if segment.isEmpty {
                lines.append("")
                continue
            }
            lines.append(contentsOf: wrapSingleLine(segment, limit: limit))
        }
        return lines
    }

    private static func wrapSingleLine(_ text: String, limit: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        var currentWidth = 0
        // 最后一个可断点（空格后的位置）及其宽度，用于回退断行
        var lastBreak: (index: String.Index, width: Int)?

        for character in text {
            let charWidth = width(String(character))
            if currentWidth + charWidth > limit, !current.isEmpty {
                if let breakPoint = lastBreak, breakPoint.index != current.startIndex {
                    let head = String(current[current.startIndex..<breakPoint.index])
                    let tail = String(current[breakPoint.index...])
                    lines.append(head.trimmingCharacters(in: .whitespaces))
                    current = tail
                    currentWidth = width(tail)
                } else {
                    lines.append(current)
                    current = ""
                    currentWidth = 0
                }
                lastBreak = nil
            }
            current.append(character)
            currentWidth += charWidth
            if character == " " {
                lastBreak = (current.endIndex, currentWidth)
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines.isEmpty ? [""] : lines
    }

    /// 截断到指定宽度并加省略号；用于标题这类必须单行的场合
    public static func truncate(_ text: String, to limit: Int) -> String {
        guard width(text) > limit, limit > 1 else { return text }
        var result = ""
        var used = 0
        for character in text {
            let charWidth = width(String(character))
            if used + charWidth > limit - 1 { break }
            result.append(character)
            used += charWidth
        }
        return result + "…"
    }
}
