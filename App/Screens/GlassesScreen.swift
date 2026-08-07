import AgentProtocol
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

/// 屏 5 · 眼镜：设备状态 + 眼镜画面实时预览（手机是眼镜的取景器）+ 自动亮屏开关。
/// 画面与快照都取聚焦主机的——真实眼镜此刻就归它驱动。
struct GlassesScreen: View {
    @ObservedObject var model: CrewViewModel
    /// Compact 底栏占位；iPad 顶栏布局关掉
    var showsDockClearance: Bool = true

    private var preview: GlassPreview.Output {
        GlassPreview.compose(screen: model.glassScreen, sessions: model.focusedSessions)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("眼镜")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(LC.text)
                    .padding(.horizontal, 4)

                deviceCard
                if isPad {
                    Text("iPad 上可挂载眼镜；Apple Watch 中转仅 iPhone。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LC.text3)
                        .padding(.horizontal, 4)
                }
                previewSection
                autoPresentCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .lcReadableWidth()
        }
        .background(LC.bg)
        .safeAreaInset(edge: .bottom) {
            if showsDockClearance {
                Color.clear.frame(height: 100)
            }
        }
    }

    // MARK: - 设备状态

    private var connected: Bool { model.glassesState == .started }

    private var deviceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 24))
                .foregroundStyle(connected ? .white : LC.text3)
                .frame(width: 52, height: 52)
                .background(LC.elev2, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ray-Ban Display")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(connected ? LC.text : LC.text2)
                Text(deviceSub)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LC.text3)
            }
            .opacity(connected ? 1 : 0.75)
            Spacer()
            if model.usingMockGlasses {
                LCChip(fontSize: 11) { Text("Mock") }
            }
            if connected {
                Menu {
                    Button("断开眼镜", role: .destructive) {
                        Task { await model.disconnectGlasses() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(LC.green).frame(width: 7, height: 7)
                        Text("在线")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LC.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(LC.green.opacity(0.12), in: Capsule())
                }
            } else {
                Button("连接") {
                    Task { await model.connectGlasses() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LC.lightBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LC.blue.opacity(0.16), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
    }

    /// 副行只写拿得到的真实状态；电量 DAT 不给，整段省略
    private var deviceSub: String {
        [sessionStateText, displayStateText].joined(separator: " · ")
    }

    private var sessionStateText: String {
        switch model.glassesState {
        case .idle: return "未连接"
        case .starting: return "连接中"
        case .started: return "已连接"
        case .paused: return "被系统抢占"
        case .stopping: return "断开中"
        case .stopped: return "已断开"
        }
    }

    private var displayStateText: String {
        switch model.displayState {
        case .stopped: return "显示未挂载"
        case .starting: return "显示挂载中"
        case .started: return "显示已挂载"
        case .stopping: return "显示卸载中"
        }
    }

    // MARK: - 实时画面

    private var previewSection: some View {
        let output = preview
        return VStack(alignment: .leading, spacing: 8) {
            // trailing 跟随眼镜端当前屏：预览是取景器，屏由眼镜上的操作驱动
            SectionHeader(title: "眼镜画面 · 实时", trailing: previewLabel(output))
            HStack {
                Spacer()
                GlassNodePreview(node: output.node)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("glasses.preview")
                Spacer()
            }
            .padding(12)
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func previewLabel(_ output: GlassPreview.Output) -> String {
        let name = kindLabel(output.kind)
        guard output.kind != .sessionList else { return name }
        return "\(name) · 第 \(output.pageIndex + 1)/\(max(output.pageCount, 1)) 页"
    }

    private func kindLabel(_ kind: GlassPreview.Kind) -> String {
        switch kind {
        case .sessionList: return "会话列表"
        case .transcript: return "流水"
        case .blockDetail: return "块详情"
        case .approval: return "审批卡"
        }
    }

    // MARK: - 自动亮屏

    private var autoPresentCard: some View {
        Toggle(
            "审批到达时自动亮屏",
            isOn: Binding(
                get: { model.autoPresentApprovals },
                set: { model.setAutoPresentApprovals($0) }
            )
        )
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(LC.text)
        .tint(LC.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - GlassScreen → GlassNode（App 层组装）

/// 把当前 glassScreen 组装成 GlassNode 树。
///
/// 复刻 LensCrewCore.GlassScreenRenderer 的分发逻辑，但吃 `[SessionState]`：
/// 快照里没有 CrewStore，而库层文件不在本次改动范围。
/// 组装块（TranscriptPaginator / GlassScreenComposer）与眼镜共用同一份，
/// 所以预览和真机看到的是同一棵树。
enum GlassPreview {
    struct Output {
        var node: GlassNode
        var pageCount: Int
        var pageIndex: Int
        var kind: Kind
    }

    enum Kind {
        case sessionList, transcript, blockDetail, approval
    }

    static func compose(
        screen: GlassScreen,
        sessions: [SessionState],
        budget: GlassLayoutBudget = .default
    ) -> Output {
        func find(_ id: String) -> SessionState? {
            sessions.first { $0.session.id == id }
        }

        switch screen {
        case .sessionList:
            return sessionList(sessions, budget: budget)

        case let .transcript(sessionID, page, following):
            guard let state = find(sessionID) else {
                return sessionList(sessions, budget: budget)
            }
            let pages = TranscriptPaginator.paginate(
                blocks: state.blocks, agent: state.session.agent, budget: budget
            )
            let index = clamp(page, count: pages.count)
            return Output(
                node: GlassScreenComposer.transcriptPage(
                    title: state.session.title,
                    agent: state.session.agent,
                    status: state.session.status,
                    pages: pages,
                    index: page,
                    following: following,
                    budget: budget
                ),
                pageCount: pages.count, pageIndex: index, kind: .transcript
            )

        case let .blockDetail(sessionID, blockID, page):
            guard let state = find(sessionID),
                  let block = state.blocks.first(where: { $0.id == blockID })
            else {
                return sessionList(sessions, budget: budget)
            }
            let pages = TranscriptPaginator.detailPages(
                for: block, agent: state.session.agent, budget: budget
            )
            let index = clamp(page, count: pages.count)
            return Output(
                node: GlassScreenComposer.blockDetail(
                    title: block.kind, pages: pages, index: page, budget: budget
                ),
                pageCount: pages.count, pageIndex: index, kind: .blockDetail
            )

        case let .approval(sessionID, approvalID, page):
            guard let state = find(sessionID),
                  let approval = state.pendingApprovals.first(where: { $0.id == approvalID })
            else {
                return sessionList(sessions, budget: budget)
            }
            // 审批卡要给选项按钮腾出高度，正文预算比普通页小（与库层一致）
            var cardBudget = budget
            cardBudget.contentLines = GlassScreenComposer.approvalDetailLines
            let pages = TranscriptPaginator.textPages(approval.detail, budget: cardBudget)
            let index = clamp(page, count: pages.count)
            return Output(
                node: GlassScreenComposer.approvalCard(
                    approval, detailPages: pages, index: page, budget: budget
                ),
                pageCount: pages.count, pageIndex: index, kind: .approval
            )
        }
    }

    private static func sessionList(
        _ sessions: [SessionState], budget: GlassLayoutBudget
    ) -> Output {
        let summaries = sessions.map { state in
            GlassSessionSummary(
                id: state.session.id,
                agent: state.session.agent,
                title: state.session.title,
                status: state.session.status,
                pendingApprovals: state.pendingApprovals.count
            )
        }
        return Output(
            node: GlassScreenComposer.sessionList(summaries, budget: budget),
            pageCount: 1, pageIndex: 0, kind: .sessionList
        )
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}

// MARK: - GlassNode → SwiftUI 迷你渲染器

/// 600×600 眼镜屏的 288×288 等比缩略。只读消费 GlassNode，
/// 按钮画出来但不接事件——预览是取景器，不是遥控器。
struct GlassNodePreview: View {
    let node: GlassNode

    var body: some View {
        GlassNodeView(node: node)
            .frame(width: 288, height: 288, alignment: .topLeading)
            .background(Color(hex: 0x050505))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(LC.line, lineWidth: 0.5)
            )
    }
}

private struct GlassNodeView: View {
    let node: GlassNode

    /// 600 → 288 的整体缩放
    private static let scale: CGFloat = 288.0 / 600.0
    /// DAT 的间距单位按 ~4px 折算（composer 的 padding 12 ≈ mockup 的 44px 边距）
    private static let unit: CGFloat = 4 * scale

    var body: some View {
        switch node {
        case let .flexBox(props, children):
            flexBox(props, children)
        case let .text(text, style, color):
            Text(text)
                .font(font(for: style))
                .foregroundStyle(color == .primary ? .white : LC.glassGreen)
                .lineLimit(style == .heading ? 2 : nil)
        case let .button(label, style, _):
            buttonView(label: label, style: style)
        case let .icon(name):
            Image(systemName: sfSymbol(for: name))
                .font(.system(size: 17))
                .foregroundStyle(LC.glassGreen)
        }
    }

    @ViewBuilder
    private func flexBox(_ props: FlexBoxProps, _ children: [GlassNode]) -> some View {
        let spacing = CGFloat(props.gap) * Self.unit
        let content = ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            GlassNodeView(node: child)
        }
        Group {
            if props.direction == .row {
                HStack(alignment: .center, spacing: spacing) {
                    if props.alignment == .center { Spacer(minLength: 0) }
                    content
                    if props.alignment == .center { Spacer(minLength: 0) }
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) { content }
                    .frame(
                        maxWidth: props.crossAlignment == .stretch ? .infinity : nil,
                        alignment: .topLeading
                    )
            }
        }
        .padding(CGFloat(props.padding) * Self.unit)
    }

    /// 三档字号按 600 屏的 36/26/20 等比折算
    private func font(for style: GlassTextStyle) -> Font {
        switch style {
        case .heading: return .system(size: 36 * Self.scale, weight: .bold)
        case .body: return .system(size: 26 * Self.scale)
        case .meta: return .system(size: 20 * Self.scale)
        }
    }

    // 显式模块限定：iOS 26 的 SwiftUI 也有个 GlassButtonStyle，不限定会歧义
    private func buttonView(
        label: String, style: GlassRenderer.GlassButtonStyle
    ) -> some View {
        let fg: Color
        let bg: Color
        let border: Color
        switch style {
        case .primary:
            fg = Color(hex: 0x050505)
            bg = LC.glassGreen
            border = LC.glassGreen
        case .secondary:
            fg = LC.glassGreen
            bg = .clear
            border = LC.glassGreen
        case .outline:
            fg = .white.opacity(0.8)
            bg = .clear
            border = .white.opacity(0.55)
        }
        return Text(label)
            .font(.system(size: 24 * Self.scale, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 26 * Self.scale)
            .padding(.vertical, 12 * Self.scale)
            .background(bg, in: RoundedRectangle(cornerRadius: 12 * Self.scale))
            .overlay(
                RoundedRectangle(cornerRadius: 12 * Self.scale)
                    .strokeBorder(border, lineWidth: 1)
            )
    }

    /// GlassIconName（DAT 图标目录）→ 最接近的 SF Symbols
    private func sfSymbol(for name: GlassIconName) -> String {
        switch name {
        case .checkmarkCircle: return "checkmark.circle"
        case .x: return "xmark"
        case .exclamationTriangle: return "exclamationmark.triangle"
        case .exclamationCircle: return "exclamationmark.circle"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .twoArrowsClockwise: return "arrow.triangle.2.circlepath"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pencilSquare: return "square.and.pencil"
        case .gear: return "gearshape"
        case .bell: return "bell"
        case .clock: return "clock"
        }
    }
}
