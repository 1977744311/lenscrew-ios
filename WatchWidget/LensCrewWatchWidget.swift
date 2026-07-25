import SwiftUI
import WidgetKit

/// W4 · Smart Stack 小组件：「待审批 N · 运行中 N」+ 最紧急一条审批摘要。
/// 数据由手表 App 在每次收到 iPhone 快照时写进 app group（见 WatchGlanceStore）
/// 并 reloadTimelines，所以时间线策略是 .never——刷新完全由 App 驱动。
@main
struct LensCrewWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        LensCrewGlanceWidget()
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: WatchGlanceStore.Glance
}

struct GlanceProvider: TimelineProvider {
    /// 画廊/占位用的示例数据，与 mockup 的 W4 同文案
    private static let sample = WatchGlanceStore.Glance(
        pendingApprovals: 1, running: 1, headline: "运行 shell 命令 · lenscrew-demo"
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

struct LensCrewGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchGlanceStore.widgetKind, provider: GlanceProvider()) { entry in
            GlanceView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("LensCrew 一瞥")
        .description("待审批与运行中的会话数")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct GlanceView: View {
    let glance: WatchGlanceStore.Glance

    private let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    private let text2 = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 9, weight: .semibold))
                Text("LensCrew")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(text2)
            countsLine
                .font(.system(size: 13.5, weight: .bold))
            Text(glance.headline ?? "暂无等待你的审批")
                .font(.system(size: 9.5))
                .foregroundStyle(text2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「待审批 N」有货才点橙色，空队列整行保持安静
    private var countsLine: Text {
        let approvals = Text("待审批 \(glance.pendingApprovals)")
            .foregroundStyle(glance.pendingApprovals > 0 ? orange : .white)
        return approvals + Text(" · ").foregroundStyle(text2) + Text("运行中 \(glance.running)")
    }
}
