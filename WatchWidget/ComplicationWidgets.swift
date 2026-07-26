// 表盘复杂功能六模块。与一瞥小组件共用 GlanceProvider 的同一份数据；
// 表盘大多以去色/着色模式渲染复杂功能，固定色只在全彩模式下用，
// 关键数字统一 .widgetAccentable() 交给系统点亮。
import SwiftUI
import WidgetKit

// MARK: - 待审批（圆形 / 边角 / 单行）

struct ApprovalsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewApprovals", provider: GlanceProvider()) { entry in
            ApprovalsView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.approvals)
        }
        .configurationDisplayName("待审批")
        .description("等待裁决的工具调用数")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct ApprovalsView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("待审批 \(glance.pendingApprovals) · 运行 \(glance.running)")
        case .accessoryCorner:
            Text("\(glance.pendingApprovals)")
                .font(.title3.bold())
                .foregroundStyle(highlight)
                .widgetAccentable()
                .widgetLabel { Text("待审批") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetPalette.text2)
                    Text("\(glance.pendingApprovals)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(highlight)
                        .widgetAccentable()
                }
            }
        }
    }

    private var highlight: Color {
        renderingMode == .fullColor && glance.pendingApprovals > 0
            ? WidgetPalette.orange : .primary
    }
}

// MARK: - 运行中会话（圆形 / 边角 / 单行）

struct RunningComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewRunning", provider: GlanceProvider()) { entry in
            RunningView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.root)
        }
        .configurationDisplayName("运行中会话")
        .description("正在跑的 agent 会话数")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct RunningView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("运行中 \(glance.running) 个会话")
        case .accessoryCorner:
            Text("\(glance.running)")
                .font(.title3.bold())
                .widgetAccentable()
                .widgetLabel { Text("运行中") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetPalette.text2)
                    Text("\(glance.running)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .widgetAccentable()
                }
            }
        }
    }
}

// MARK: - 额度环（圆形 / 边角 / 单行）

/// 主窗口 = 快照里的第一行额度（iPhone 侧已按主机名与主桶优先排好）
private func mainQuota(_ glance: WatchGlanceStore.Glance) -> WatchGlanceStore.QuotaGlance? {
    glance.quota.first
}

/// 环里那一两个字：优先窗口时长（周/5h），没有就退到 Codex
private func quotaCaption(_ row: WatchGlanceStore.QuotaGlance) -> String {
    WatchGlanceStore.windowName(mins: row.windowDurationMins) ?? "Codex"
}

struct QuotaRingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewQuotaRing", provider: GlanceProvider()) { entry in
            QuotaRingView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.root)
        }
        .configurationDisplayName("Codex 额度环")
        .description("账号剩余额度百分比")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct QuotaRingView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if let row = mainQuota(glance) {
            content(row)
        } else {
            empty
        }
    }

    @ViewBuilder
    private func content(_ row: WatchGlanceStore.QuotaGlance) -> some View {
        let remaining = row.remainingPercent
        let tint: Color =
            renderingMode == .fullColor ? WidgetPalette.quotaTint(remaining: remaining) : .primary
        switch family {
        case .accessoryInline:
            Text("Codex 余 \(remaining)% · \(quotaCaption(row))")
        case .accessoryCorner:
            Text("\(remaining)%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .widgetAccentable()
                .widgetLabel {
                    Gauge(value: Double(remaining), in: 0...100) { Text("Codex") }
                        .tint(tint)
                }
        default:
            Gauge(value: Double(remaining), in: 0...100) {
                Text(quotaCaption(row))
            } currentValueLabel: {
                Text("\(remaining)")
                    .font(.system(.body, design: .rounded).bold())
            }
            .gaugeStyle(.accessoryCircular)
            .tint(tint)
            .widgetAccentable()
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        case .accessoryInline:
            Text("Codex 额度 —")
        case .accessoryCorner:
            Text("—").widgetLabel { Text("Codex") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("—").font(.system(size: 16, weight: .bold))
                    Text("Codex").font(.system(size: 9)).foregroundStyle(WidgetPalette.text2)
                }
            }
        }
    }
}

// MARK: - 额度详情（矩形）

struct QuotaDetailComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewQuotaDetail", provider: GlanceProvider()) { entry in
            QuotaDetailView(glance: entry.glance, now: entry.date)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.root)
        }
        .configurationDisplayName("Codex 额度详情")
        .description("各额度窗口的剩余与新鲜度")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct QuotaDetailView: View {
    let glance: WatchGlanceStore.Glance
    let now: Date
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// 采集超过 90 分钟才提醒陈旧；正常节奏下不值得占一行
    private var staleNote: String? {
        guard let capturedAtMs = glance.quotaCapturedAtMs else { return nil }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: Double(capturedAtMs) / 1000))
        guard age > 90 * 60 else { return nil }
        return "更新于 \(Int(age / 3600)) 小时前"
    }

    /// 主机重名去重后仍多于一台才在行里标主机
    private var multiHost: Bool { Set(glance.quota.map(\.hostName)).count > 1 }

    var body: some View {
        if glance.quota.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header
                Text("暂无额度数据")
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetPalette.text2)
                Text("连上 Mac 后自动补数")
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetPalette.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2.5) {
                header
                ForEach(Array(glance.quota.prefix(2).enumerated()), id: \.offset) { _, row in
                    quotaRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 9, weight: .semibold))
            Text("Codex 额度")
                .font(.system(size: 9, weight: .semibold))
            Spacer(minLength: 0)
            if let staleNote {
                Text(staleNote).font(.system(size: 8))
            }
        }
        .foregroundStyle(WidgetPalette.text2)
    }

    private func quotaRow(_ row: WatchGlanceStore.QuotaGlance) -> some View {
        let tint: Color =
            renderingMode == .fullColor
            ? WidgetPalette.quotaTint(remaining: row.remainingPercent) : .primary
        return HStack(spacing: 5) {
            Text(rowName(row))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            Gauge(value: Double(row.remainingPercent), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            Text("\(row.remainingPercent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .widgetAccentable()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func rowName(_ row: WatchGlanceStore.QuotaGlance) -> String {
        let window = WatchGlanceStore.windowName(mins: row.windowDurationMins)
        let base = row.label ?? window ?? "Codex"
        return multiHost ? "\(row.hostName)·\(base)" : base
    }
}

// MARK: - 组合卡（矩形）：任务 + 额度一格看全

struct ComboComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewCombo", provider: GlanceProvider()) { entry in
            ComboView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.target(pendingApprovals: entry.glance.pendingApprovals))
        }
        .configurationDisplayName("任务 + 额度")
        .description("待审批、运行中与剩余额度")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct ComboView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            countsLine
                .font(.system(size: 12.5, weight: .bold))
                .widgetAccentable()
            if let row = mainQuota(glance) {
                quotaLine(row)
            }
            Text(footline)
                .font(.system(size: 9))
                .foregroundStyle(WidgetPalette.text2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countsLine: Text {
        let highlight: Color =
            renderingMode == .fullColor && glance.pendingApprovals > 0
            ? WidgetPalette.orange : .primary
        return Text("待审批 \(glance.pendingApprovals)").foregroundStyle(highlight)
            + Text(" · ").foregroundStyle(WidgetPalette.text2)
            + Text("运行 \(glance.running)")
    }

    private func quotaLine(_ row: WatchGlanceStore.QuotaGlance) -> some View {
        let tint: Color =
            renderingMode == .fullColor
            ? WidgetPalette.quotaTint(remaining: row.remainingPercent) : .primary
        return HStack(spacing: 5) {
            Text(WatchGlanceStore.windowName(mins: row.windowDurationMins) ?? "Codex")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WidgetPalette.text2)
            Gauge(value: Double(row.remainingPercent), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            Text("\(row.remainingPercent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .widgetAccentable()
        }
    }

    private var footline: String {
        glance.headline ?? "已连 \(glance.connectedHosts) 台 Mac"
    }
}

// MARK: - 主机状态（圆形 / 单行）

struct HostsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LensCrewHosts", provider: GlanceProvider()) { entry in
            HostsView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
                .widgetURL(WidgetLink.root)
        }
        .configurationDisplayName("已连主机")
        .description("当前连接的 Mac 数")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

private struct HostsView: View {
    let glance: WatchGlanceStore.Glance
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("已连 \(glance.connectedHosts) 台 Mac")
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetPalette.text2)
                    Text("\(glance.connectedHosts)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .widgetAccentable()
                }
            }
        }
    }
}
