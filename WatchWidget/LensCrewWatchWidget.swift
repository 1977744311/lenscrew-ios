import SwiftUI
import WidgetKit

/// 小组件 bundle：W4 Smart Stack 一瞥 + 六个表盘复杂功能模块。
/// 全部模块共用 WatchGlanceStore 的同一份数据与同一个 provider——
/// 数据由手表 App 在每次收到 iPhone 快照（含表盘后台通道）时写入并全量刷新。
@main
struct LensCrewWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        LensCrewGlanceWidget()
        ApprovalsComplication()
        RunningComplication()
        QuotaRingComplication()
        QuotaDetailComplication()
        ComboComplication()
        HostsComplication()
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: WatchGlanceStore.Glance
}

struct GlanceProvider: TimelineProvider {
    /// 画廊/占位用的示例数据，与 mockup 的 W4 同文案；额度行用真实形状
    static let sample = WatchGlanceStore.Glance(
        pendingApprovals: 1, running: 1, headline: "运行 shell 命令 · lenscrew-demo",
        connectedHosts: 2,
        quota: [
            WatchGlanceStore.QuotaGlance(
                hostName: "MBP", label: nil, remainingPercent: 82,
                windowDurationMins: 10_080, resetsAt: nil
            ),
            WatchGlanceStore.QuotaGlance(
                hostName: "MBP", label: "GPT-5.3-Codex-Spark", remainingPercent: 64,
                windowDurationMins: 10_080, resetsAt: nil
            ),
        ],
        quotaCapturedAtMs: nil
    )

    private static var current: WatchGlanceStore.Glance {
        WatchGlanceStore.load()
            ?? WatchGlanceStore.Glance(pendingApprovals: 0, running: 0, headline: nil)
    }

    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(GlanceEntry(date: .now, glance: context.isPreview ? Self.sample : Self.current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Timeline(entries: [GlanceEntry(date: .now, glance: Self.current)], policy: .never))
    }
}

// MARK: - 共享调色与深链

enum WidgetPalette {
    static let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let text2 = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.62)

    /// 剩余额度的语义色（只在全彩模式用；表盘去色模式交给系统着色）
    static func quotaTint(remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return orange }
        return .green
    }
}

enum WidgetLink {
    /// 深链两端约定见 Watch/LensCrewWatchApp.swift 的 onOpenURL
    static let approvals = URL(string: "lenscrew://approvals")!
    static let root = URL(string: "lenscrew://root")!

    /// 有待批直达审批队列，否则回根列表
    static func target(pendingApprovals: Int) -> URL {
        pendingApprovals > 0 ? approvals : root
    }
}

// MARK: - W4 · Smart Stack / 矩形槽一瞥

struct LensCrewGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchGlanceStore.widgetKind, provider: GlanceProvider()) { entry in
            GlanceView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.target(pendingApprovals: entry.glance.pendingApprovals))
        }
        .configurationDisplayName("LensCrew 一瞥")
        .description("待审批与运行中的会话数")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct GlanceView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 9, weight: .semibold))
                Text("LensCrew")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(WidgetPalette.text2)
            countsLine
                .font(.system(size: 13.5, weight: .bold))
                .widgetAccentable()
            Text(glance.headline ?? "暂无等待你的审批")
                .font(.system(size: 9.5))
                .foregroundStyle(WidgetPalette.text2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「待审批 N」有货才点橙色，空队列整行保持安静；表盘去色模式交给系统统一着色
    private var countsLine: Text {
        let highlight: Color =
            renderingMode == .fullColor && glance.pendingApprovals > 0
            ? WidgetPalette.orange : .white
        let approvals = Text("待审批 \(glance.pendingApprovals)").foregroundStyle(highlight)
        return approvals + Text(" · ").foregroundStyle(WidgetPalette.text2)
            + Text("运行中 \(glance.running)")
    }
}
