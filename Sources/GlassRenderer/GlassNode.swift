// 布局树 —— 与 DAT 的 FlexBox DSL 同构的中间表示。
// 严格对齐 0.8.0 的硬约束：只有 6 类组件、文字 3 字号 × 2 色、整屏替换、仅垂直滚动。
// 做成中间表示而不是直接调 SDK，是为了让布局能脱离真机做快照单测。
import Foundation

public enum GlassTextStyle: String, Sendable, Codable, CaseIterable {
    case heading, body, meta
}

public enum GlassTextColor: String, Sendable, Codable {
    case primary, secondary
}

public enum GlassDirection: String, Sendable, Codable {
    case column, row
}

public enum GlassAlignment: String, Sendable, Codable {
    case start, center, end, stretch
}

public enum GlassButtonStyle: String, Sendable, Codable {
    case primary, secondary, outline
}

/// 名字逐个对照 0.8.0 的 116 项图标目录核过（MWDATDisplay.swiftinterface 的 IconName），
/// 所以 App 侧适配器是零近似的 1:1 映射。要加新图标先回去核目录，不要凭直觉起名。
public enum GlassIconName: String, Sendable, Codable {
    case checkmarkCircle, x, exclamationTriangle, exclamationCircle
    case arrowLeft, arrowRight, twoArrowsClockwise
    case code, pencilSquare, gear, bell, clock
}

public indirect enum GlassNode: Sendable, Equatable, Codable {
    case flexBox(FlexBoxProps, children: [GlassNode])
    case text(String, style: GlassTextStyle, color: GlassTextColor)
    case button(label: String, style: GlassButtonStyle, actionID: String)
    case icon(GlassIconName)
}

public struct FlexBoxProps: Sendable, Equatable, Codable {
    public var direction: GlassDirection
    public var gap: Int
    public var alignment: GlassAlignment
    public var crossAlignment: GlassAlignment
    public var padding: Int
    /// 整块可点区域的动作 ID；nil 表示不可点
    public var actionID: String?

    public init(
        direction: GlassDirection = .column, gap: Int = 0,
        alignment: GlassAlignment = .start, crossAlignment: GlassAlignment = .start,
        padding: Int = 0, actionID: String? = nil
    ) {
        self.direction = direction
        self.gap = gap
        self.alignment = alignment
        self.crossAlignment = crossAlignment
        self.padding = padding
        self.actionID = actionID
    }
}

public enum GlassNodeEncoder {
    /// 键排序的稳定 JSON —— DisplayPayload 与快照测试共用同一份序列化，
    /// 顺带成为整屏去重的比较依据。
    public static func canonicalJSON(_ node: GlassNode) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(node), as: UTF8.self)
    }
}
