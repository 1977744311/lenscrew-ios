import AgentProtocol
import LensCrewCore
import SwiftUI

/// 屏 2 · 会话流水：压缩导航头 + 按块样式渲染的流水 + 底部 composer。
/// 用 (hostID, sessionID) 复合键寻址，所有动作路由到会话所属主机。
struct SessionScreen: View {
    let model: CrewViewModel
    let sessionKey: SessionKey
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var expandedReasoning: Set<String> = []
    @State private var expandedShells: Set<String> = []
    @State private var presentedApproval: ApprovalPresentation?
    @State private var gitRoute: GitRoute?
    @State private var dictation = SpeechDictation()
    /// 听写开始时的草稿快照；识别的 partial 结果整段替换其后的部分
    @State private var dictationBase = ""

    private var state: SessionState? {
        model.sessionState(for: sessionKey)
    }

    private var pendingIDs: [String] {
        state?.pendingApprovals.map(\.id) ?? []
    }

    var body: some View {
        Group {
            if let state {
                content(state)
            } else {
                ContentUnavailableView("会话已结束", systemImage: "xmark.circle")
            }
        }
        .background(LC.bg)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(item: $presentedApproval) { presentation in
            ApprovalSheet(model: model, presentation: presentation)
        }
        .fullScreenCover(item: $gitRoute) { route in
            GitScreen(model: model, route: route)
        }
        // 新审批到达自动弹 sheet；结清（approvalSettled）才撤，不做乐观关闭
        .onChange(of: pendingIDs) { old, new in
            if let presented = presentedApproval, !new.contains(presented.approval.id) {
                presentedApproval = nil
            }
            if presentedApproval == nil,
               let freshID = new.first(where: { !old.contains($0) }) {
                presentApproval(id: freshID)
            }
        }
        // 听写的 partial 结果是全量替换式：草稿 = 开始时的快照 + 当前识别文本
        .onChange(of: dictation.transcript) { _, transcript in
            guard dictation.isListening || !transcript.isEmpty else { return }
            draft = dictationBase + transcript
        }
        .onDisappear { dictation.cancel() }
    }

    private func content(_ state: SessionState) -> some View {
        VStack(spacing: 0) {
            navHeader(state)
            transcript(state)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let approval = state.pendingApprovals.first {
                    pendingApprovalRow(approval)
                }
                if state.session.status == .ended || state.session.status == .error {
                    deadSessionBar(state)
                } else {
                    composer(state)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(LC.bg.opacity(0.94))
        }
    }

    // MARK: - 压缩导航头

    private func navHeader(_ state: SessionState) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LC.elev, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.session.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LC.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    AgentBadge(agent: state.session.agent)
                    modelLabel(state)
                    StatusPill(style: .session(state.session.status))
                }
            }
            Spacer()
            gitButton(state)
            glassesButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// git 操作面板入口：仓库即会话的 workspaceRoot
    private func gitButton(_ state: SessionState) -> some View {
        Button {
            gitRoute = GitRoute(
                hostID: sessionKey.hostID,
                workspaceRoot: state.session.workspaceRoot
            )
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15))
                .foregroundStyle(LC.text2)
                .frame(width: 34, height: 34)
                .background(LC.elev, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("git 面板")
        .accessibilityIdentifier("session.gitPanel")
    }

    /// 模型名：单行截断（cursor 的模型 id 自带参数很长，不截会把导航头挤成三行）；
    /// 会话自陈了模型清单时可点切换——codex 下一轮生效，claude/cursor 即时生效。
    /// codex 的推理档挂在同一个菜单里（当前模型自陈支持的档位），显示为 "模型 · 档"。
    @ViewBuilder
    private func modelLabel(_ state: SessionState) -> some View {
        if let modelID = state.session.model {
            let current = state.session.models.first { $0.id == modelID }
            let effortSuffix = state.session.reasoningEffort.map { " · \($0)" } ?? ""
            let display = (current?.label ?? modelID) + effortSuffix
            if state.session.models.count > 1 || !(current?.reasoningEfforts.isEmpty ?? true) {
                Menu {
                    if let efforts = current?.reasoningEfforts, !efforts.isEmpty {
                        Section("推理程度") {
                            ForEach(efforts, id: \.self) { effort in
                                Button {
                                    Task {
                                        await model.setSessionReasoningEffort(
                                            sessionKey, effort: effort)
                                    }
                                } label: {
                                    if effort == state.session.reasoningEffort {
                                        Label(effort, systemImage: "checkmark")
                                    } else {
                                        Text(effort)
                                    }
                                }
                            }
                        }
                    }
                    Section("会话模型") {
                        ForEach(state.session.models) { option in
                            Button {
                                Task { await model.setSessionModel(sessionKey, modelID: option.id) }
                            } label: {
                                if option.id == modelID {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(display)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(LC.text3)
                }
                .accessibilityIdentifier("session.modelChip")
            } else {
                Text(display)
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// 眼镜挂载状态入口：绿=已挂载
    private var glassesButton: some View {
        Menu {
            Section(model.glassesMounted ? "眼镜已挂载" : "眼镜未挂载") {
                if model.glassesMounted {
                    Button("断开眼镜", role: .destructive) {
                        Task { await model.disconnectGlasses() }
                    }
                } else {
                    Button("连接并挂载显示") {
                        Task { await model.connectGlasses() }
                    }
                }
            }
        } label: {
            Image(systemName: "eyeglasses")
                .font(.system(size: 15))
                .foregroundStyle(model.glassesMounted ? LC.green : LC.text2)
                .frame(width: 34, height: 34)
                .background(LC.elev, in: Circle())
        }
    }

    // MARK: - 流水

    private enum TranscriptItem: Identifiable {
        case block(TranscriptBlock)
        case turnBreak(TurnMarker)

        var id: String {
            switch self {
            case let .block(block): return "b-\(block.id)"
            case let .turnBreak(marker): return "t-\(marker.id)"
            }
        }
    }

    /// 块 + 轮次分隔线按锚点交错
    private func items(_ state: SessionState) -> [TranscriptItem] {
        let markers = Dictionary(
            grouping: model.turnMarkers(for: sessionKey), by: \.afterBlockID
        )
        var result: [TranscriptItem] = []
        for block in state.blocks {
            result.append(.block(block))
            for marker in markers[block.id] ?? [] {
                result.append(.turnBreak(marker))
            }
        }
        return result
    }

    private func transcript(_ state: SessionState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(items(state)) { item in
                        Group {
                            switch item {
                            case let .block(block):
                                blockView(block)
                            case let .turnBreak(marker):
                                turnBreakView(marker)
                            }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: state.blocks.count) {
                guard let last = items(state).last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case let .userMessage(_, text, _):
            userBubble(text)
        case let .agentMessage(_, text, streaming):
            Text(streaming ? text + "▍" : text)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(LC.text)
                .textSelection(.enabled)
        case let .reasoning(id, text, streaming):
            reasoningRow(id: id, text: text, streaming: streaming)
        case let .shellCommand(id, command, _, output, exitCode, status):
            shellBlock(
                id: id, command: command, output: output, exitCode: exitCode, status: status
            )
        case let .fileChange(_, files, status):
            fileChangeCard(files: files, status: status)
        case let .toolCall(id, source, tool, summary, output, status):
            toolCallCard(
                id: id, source: source, tool: tool, summary: summary,
                output: output, status: status
            )
        case let .plan(_, steps):
            planCard(steps)
        case let .error(_, message):
            thinRow {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(LC.red)
                Text(message).foregroundStyle(LC.red)
            }
        }
    }

    /// 用户消息：右对齐青蓝气泡
    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(Color(hex: 0xEAF6FF))
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    Color(hex: 0x32424E),
                    in: UnevenRoundedRectangle(cornerRadii: .init(
                        topLeading: 18, bottomLeading: 18, bottomTrailing: 5, topTrailing: 18
                    ))
                )
                .frame(maxWidth: 300, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 思考：细行，可点展开全文。事件里没有耗时，不写「N 秒」。
    /// 有的模型/配置不外发思考内容（codex 的 summary 可能为空）——
    /// 没有内容就渲染成静态行：不给展开箭头，也不能包成禁用按钮，
    /// 禁用态会把本就 34% 透明的细字再调暗一层，直接沉进黑背景。
    @ViewBuilder
    private func reasoningRow(id: String, text: String, streaming: Bool) -> some View {
        if text.isEmpty {
            thinRow {
                Text(streaming ? "思考中…" : "思考")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if expandedReasoning.contains(id) {
                        expandedReasoning.remove(id)
                    } else {
                        expandedReasoning.insert(id)
                    }
                } label: {
                    thinRow {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expandedReasoning.contains(id) ? 90 : 0))
                        Text(streaming ? "思考中…" : "思考")
                    }
                }
                .buttonStyle(.plain)
                if expandedReasoning.contains(id) {
                    Text(streaming ? text + "▍" : text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(LC.text2)
                        .textSelection(.enabled)
                        .padding(.leading, 16)
                }
            }
        }
    }

    /// shell：没有产出前是一条细行，有了输出/结果才升级成卡片
    @ViewBuilder
    private func shellBlock(
        id: String, command: String, output: String, exitCode: Int?, status: BlockStatus
    ) -> some View {
        if status == .pending {
            thinRow {
                Circle().fill(LC.orange).frame(width: 5, height: 5)
                Text("等待批准 · ").foregroundStyle(LC.text3)
                    + Text(command).font(.system(size: 12.5, design: .monospaced))
            }
        } else if status == .running, output.isEmpty {
            thinRow {
                PulseDot(color: LC.runningOrange, size: 5)
                Text("正在执行 · ").foregroundStyle(LC.text3)
                    + Text(command).font(.system(size: 12.5, design: .monospaced))
            }
        } else {
            toolCard {
                toolCardHead {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(LC.text2)
                    Text(command)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(LC.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusPill(style: .block(status, exitCode: exitCode))
                }
                if !output.isEmpty {
                    shellOutput(id: id, output: output)
                }
            }
        }
    }

    private static let collapsedOutputLines = 5

    private func shellOutput(id: String, output: String) -> some View {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let expanded = expandedShells.contains(id)
        let visible = expanded ? lines : Array(lines.prefix(Self.collapsedOutputLines))
        let hidden = lines.count - visible.count
        return VStack(alignment: .leading, spacing: 0) {
            Text(visible.joined(separator: "\n"))
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(LC.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.35))
            if hidden > 0 || expanded {
                Button {
                    if expanded {
                        expandedShells.remove(id)
                    } else {
                        expandedShells.insert(id)
                    }
                } label: {
                    HStack {
                        Text(expanded ? "收起输出" : "展开其余 \(hidden) 行")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LC.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Hairline() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fileChangeCard(files: [FileChangeSummary], status: BlockStatus) -> some View {
        toolCard {
            toolCardHead {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text2)
                if files.count == 1, let file = files.first {
                    Text(fileName(file.path))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(LC.text)
                        .lineLimit(1)
                    diffCounts(file)
                } else {
                    Text("改动 \(files.count) 个文件")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LC.text)
                }
                Spacer(minLength: 8)
                StatusPill(
                    style: status == .ok ? .applied : .block(status, exitCode: nil)
                )
            }
            if files.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(files, id: \.path) { file in
                        HStack(spacing: 6) {
                            Text(file.path)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(LC.text2)
                                .lineLimit(1)
                            diffCounts(file)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }

    /// 行数拿不到时不显示 "+0 −0"——那是在撒谎
    @ViewBuilder
    private func diffCounts(_ file: FileChangeSummary) -> some View {
        if let added = file.added, let removed = file.removed {
            (Text("+\(added)").foregroundStyle(LC.green)
                + Text(" −\(removed)").foregroundStyle(LC.red))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }

    private func toolCallCard(
        id: String, source: String?, tool: String, summary: String,
        output: String, status: BlockStatus
    ) -> some View {
        toolCard {
            toolCardHead {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(LC.text2)
                Text(source.map { "\($0) · \(tool)" } ?? tool)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LC.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(style: .block(status, exitCode: nil))
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, output.isEmpty ? 9 : 4)
            }
            if !output.isEmpty {
                shellOutput(id: id, output: output)
            }
        }
    }

    private func planCard(_ steps: [PlanStep]) -> some View {
        toolCard {
            toolCardHead {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(LC.text2)
                Text("计划")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LC.text)
                Spacer(minLength: 8)
                let done = steps.filter { $0.status == .done }.count
                Text("\(done)/\(steps.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LC.text3)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(planMarker(step.status))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(planColor(step.status))
                        Text(step.text)
                            .font(.system(size: 13))
                            .foregroundStyle(step.status == .done ? LC.text3 : LC.text2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    private func planMarker(_ status: PlanStep.Status) -> String {
        switch status {
        case .pending: return "·"
        case .running: return "▸"
        case .done: return "✓"
        }
    }

    private func planColor(_ status: PlanStep.Status) -> Color {
        switch status {
        case .pending: return LC.text3
        case .running: return LC.runningOrange
        case .done: return LC.green
        }
    }

    /// 轮次分隔线：两侧发丝线夹用量。时长拿不到，只写有的字段。
    private func turnBreakView(_ marker: TurnMarker) -> some View {
        var parts: [String] = []
        if let total = marker.totalTokens { parts.append("\(formatTokens(total)) tokens") }
        if let percent = marker.cacheHitPercent { parts.append("缓存命中 \(percent)%") }
        return HStack(spacing: 8) {
            Hairline().frame(maxWidth: .infinity)
            Text("本轮 " + parts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(LC.text3)
                .fixedSize()
            Hairline().frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
    }

    private func thinRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12.5))
            .foregroundStyle(LC.text3)
    }

    private func toolCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LC.elev)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).strokeBorder(LC.line, lineWidth: 0.5)
            )
    }

    private func toolCardHead(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    // MARK: - 审批入口 + composer

    /// sheet 被划掉后还能从这行回去；审批还挂着就不该从视野里消失
    private func pendingApprovalRow(_ approval: ApprovalRequest) -> some View {
        Button {
            presentApproval(id: approval.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text("等你审批 · \(approval.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(LC.orange)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(LC.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session.approvalRow")
    }

    private func presentApproval(id: String) {
        guard let state,
              let approval = state.pendingApprovals.first(where: { $0.id == id })
        else { return }
        presentedApproval = ApprovalPresentation(
            sessionKey: sessionKey,
            sessionTitle: state.session.title,
            agent: state.session.agent,
            approval: approval
        )
    }

    /// 死会话把输入区换成结局横条：原生会话还在 agent 自己的状态目录里，
    /// 可续接时给一键续接（新行出现在首页列表顶部），不可续接就只说明现状
    private func deadSessionBar(_ state: SessionState) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.session.status == .error ? "会话出错了" : "会话已结束")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LC.text)
                Text(state.isResumable ? "上下文没丢，续接后从首页进新会话" : "没留下可续接的原生会话")
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text2)
            }
            Spacer(minLength: 8)
            if state.isResumable {
                Button {
                    Task {
                        await model.resumeSession(sessionKey)
                        dismiss()
                    }
                } label: {
                    Label("续接", systemImage: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(LC.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session.resume")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 16))
    }

    private func composer(_ state: SessionState) -> some View {
        let running = state.session.status == .running
        let draftEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 5) {
            if let hint = dictation.lastError {
                HStack(spacing: 5) {
                    Image(systemName: "mic.slash").font(.system(size: 10))
                    Text(hint).font(.system(size: 11.5))
                    Spacer()
                }
                .foregroundStyle(LC.red)
                .padding(.horizontal, 6)
            }
            HStack(spacing: 8) {
                modeChip(state)
                TextField(
                    dictation.isListening ? "正在听写…" : "追加指令，运行中也可排队…",
                    text: $draft, axis: .vertical
                )
                .font(.system(size: 15))
                .foregroundStyle(LC.text)
                .lineLimit(1...4)
                micButton
                // 运行中且没在打字 → 中断钮；其余情况 → 发送钮（运行中也可排队）
                if running, draftEmpty, !dictation.isListening {
                    Button {
                        Task { await model.interrupt(sessionKey) }
                    } label: {
                        Image(systemName: "square.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(LC.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("中断")
                } else {
                    Button {
                        dictation.cancel()
                        let text = draft
                        draft = ""
                        Task { await model.send(text, to: sessionKey) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(draftEmpty ? LC.elev2 : LC.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draftEmpty)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(LC.elev2.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24).strokeBorder(LC.line, lineWidth: 0.5)
        )
    }

    /// 模式 chip：点开列出本会话可切换的档位（bridge 快照自陈）。
    /// codex 的切换从下一轮 turn 生效，claude/cursor 即时生效；
    /// chip 文本以 bridge 回推的 sessionUpdated 为准，不做乐观更新。
    @ViewBuilder
    private func modeChip(_ state: SessionState) -> some View {
        if let current = model.sessionMode(for: sessionKey) {
            if state.session.modes.count > 1 {
                Menu {
                    Section("会话模式") {
                        ForEach(state.session.modes) { option in
                            Button(role: AgentModes.isDangerous(option.id) ? .destructive : nil) {
                                Task { await model.setSessionMode(sessionKey, modeID: option.id) }
                            } label: {
                                if option.id == current.id {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                    Text(option.detail)
                                }
                            }
                        }
                    }
                } label: {
                    LCChip(fontSize: 11.5) {
                        Text(current.label)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .accessibilityIdentifier("session.modeChip")
            } else {
                LCChip(fontSize: 11.5) {
                    Text(current.label)
                }
            }
        }
    }

    /// 语音输入：点一下开始听写、再点结束。识别文本实时进草稿，发送仍由发送键决定
    private var micButton: some View {
        Button {
            if dictation.isListening {
                dictation.stop()
            } else {
                dictationBase = draft.isEmpty ? "" : draft + " "
                dictation.start()
            }
        } label: {
            Image(systemName: dictation.isListening ? "waveform" : "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(dictation.isListening ? .white : LC.text2)
                .frame(width: 34, height: 34)
                .background(dictation.isListening ? LC.red : .clear, in: Circle())
                .symbolEffect(
                    .variableColor.iterative, options: .repeating,
                    isActive: dictation.isListening
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isListening ? "结束听写" : "语音输入")
        .accessibilityIdentifier("session.dictation")
    }
}
