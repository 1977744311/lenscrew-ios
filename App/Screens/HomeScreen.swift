import AgentProtocol
import BridgeLink
import LensCrewCore
import SwiftUI

/// 屏 1 · 指挥台：跨主机合并的审批队列置顶 + 全部主机会话按最近活动统一排序。
struct HomeScreen: View {
    @ObservedObject var model: CrewViewModel
    @Binding var path: [SessionKey]
    /// Regular 分栏：非 nil 时点会话写选中，不再 path.append
    var selectedSession: Binding<SessionKey?>? = nil
    /// Compact 底栏占位；分栏侧栏里关掉
    var showsDockClearance: Bool = true
    @State private var filter: AgentKind?
    /// 已发出裁决、还没等到 approvalSettled 的审批：期间禁用按钮防止重复提交，
    /// 但卡不撤——撤卡的唯一依据是 bridge 的结清事件。键是 hostID#approvalID。
    @State private var resolvingApprovals: Set<String> = []

    private var isSelectionMode: Bool { selectedSession != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                    .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.lastError {
                        errorRow(error)
                    }
                    if !model.pendingApprovalItems.isEmpty {
                        approvalsSection
                    }
                    sessionsSection
                    if !model.hostQuotas.isEmpty {
                        quotaSection
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 4)
        }
        .background(LC.bg)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if showsDockClearance {
                Color.clear.frame(height: 100)
            }
        }
    }

    private func openSession(_ key: SessionKey) {
        if let selectedSession {
            selectedSession.wrappedValue = key
        } else {
            path.append(key)
        }
    }

    private func isSelected(_ key: SessionKey) -> Bool {
        selectedSession?.wrappedValue == key
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LensCrew")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(LC.text)
                Spacer()
                hostChip
            }
            HStack(spacing: 6) {
                LCChip {
                    Image(systemName: model.glassesMounted ? "eyeglasses" : "eyeglasses.slash")
                        .font(.system(size: 12))
                    Text(model.glassesMounted ? "眼镜已挂载" : "眼镜未挂载")
                }
                if model.isConnected {
                    LCChip { Text("\(model.aggregatedSessions.count) 个会话") }
                }
            }
        }
    }

    /// 主机状态 chip，点击弹快速切换菜单；chip 本体展示 active 主机的连接面
    private var hostChip: some View {
        Menu {
            ForEach(model.hosts.hosts) { host in
                Button {
                    Task { await model.switchHost(to: host.id) }
                } label: {
                    if host.id == model.hosts.activeHostID {
                        Label(menuTitle(host), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(host))
                    }
                }
            }
            if model.hosts.active != nil, !activeConnected {
                Divider()
                Button("重新连接") {
                    guard let id = model.hosts.activeHostID else { return }
                    Task { await model.connectHost(id) }
                }
            }
        } label: {
            LCChip {
                Circle().fill(linkColor).frame(width: 7, height: 7)
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text(hostChipText)
            }
        }
    }

    /// 多主机时给掉线的主机标出状态，切过去之前就能看到；单主机沿用纯名称
    private func menuTitle(_ host: BridgeHostConfig) -> String {
        guard model.hosts.hosts.count > 1,
              model.link(for: host.id)?.isConnected != true
        else { return host.name }
        return "\(host.name) · 未连接"
    }

    private var activeConnected: Bool {
        if case .connected = model.linkState { return true }
        return false
    }

    private var hostChipText: String {
        guard let host = model.hosts.active else { return "未配置电脑" }
        switch model.linkState {
        case .connected:
            var parts = [host.name]
            if let ms = model.latencyMs { parts.append("\(ms)ms") }
            if let path = model.linkPath { parts.append(path.label) }
            return parts.joined(separator: " · ")
        case .connecting:
            return "\(host.name) · 连接中"
        case .disconnected, .failed:
            return "\(host.name) · 未连接"
        }
    }

    private var linkColor: Color {
        switch model.linkState {
        case .connected: return LC.green
        case .connecting: return LC.orange
        case .disconnected: return LC.text3
        case .failed: return LC.red
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 12))
            Text(message).lineLimit(2)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LC.red)
        .padding(.horizontal, 4)
    }

    // MARK: - 等你审批

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "等你审批 · \(model.pendingApprovalItems.count)",
                titleColor: LC.orange
            )
            .accessibilityIdentifier("home.approvalsHeader")
            ForEach(model.pendingApprovalItems) { item in
                approvalCard(item)
            }
        }
    }

    private func approvalCard(_ item: PendingApprovalItem) -> some View {
        let approval = item.approval
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentBadge(agent: item.session.agent)
                Text(item.session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text3)
                    .lineLimit(1)
                if model.hosts.hosts.count > 1 {
                    LCChip(fontSize: 10) { Text(item.hostName) }
                }
                Spacer()
                Text(relativeTime(fromMs: approval.requestedAtMs))
                    .font(.system(size: 12))
                    .foregroundStyle(LC.text3)
            }
            HStack(spacing: 7) {
                Image(systemName: approvalIcon(approval.kind))
                    .font(.system(size: 15))
                    .foregroundStyle(LC.orange)
                Text(approval.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LC.text)
                    .lineLimit(1)
            }
            Text(approval.detail.split(separator: "\n").first.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LC.text2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            let resolving = resolvingApprovals.contains(item.id)
            HStack(spacing: 8) {
                LCButton(title: "查看上下文", kind: .tinted, minHeight: 40, fontSize: 14) {
                    openSession(item.key)
                }
                .accessibilityIdentifier("home.approval.context")
                if let once = onceAllowOption(approval) {
                    LCButton(
                        title: resolving ? "等待确认…" : "允许一次",
                        kind: .primary, minHeight: 40, fontSize: 14
                    ) {
                        resolvingApprovals.insert(item.id)
                        Task {
                            await model.resolve(
                                approval: approval, in: item.key, optionID: once.id
                            )
                        }
                    }
                    .disabled(resolving)
                    .opacity(resolving ? 0.6 : 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(LC.orange.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.approvalCard")
    }

    private func onceAllowOption(_ approval: ApprovalRequest) -> ApprovalOption? {
        approval.options.first { $0.kind == .allow && $0.scope == .once }
    }

    // MARK: - 会话列表

    /// 聚合列表：全部主机的会话，VM 已按最近活动跨主机统一排序
    private var orderedSessions: [AggregatedSession] {
        model.aggregatedSessions
    }

    private var filteredSessions: [AggregatedSession] {
        guard let filter else { return orderedSessions }
        return orderedSessions.filter { $0.state.session.agent == filter }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "会话", trailing: "按最近活动")
            filterChips
            if filteredSessions.isEmpty {
                emptySessionsCard
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSessions.enumerated()), id: \.element.id) {
                        index, item in
                        if index > 0 {
                            Hairline().padding(.leading, 16)
                        }
                        sessionLink(item)
                            .accessibilityIdentifier("home.sessionCard")
                            .contextMenu {
                                if item.state.isResumable {
                                    Button {
                                        Task { await model.resumeSession(item.key) }
                                    } label: {
                                        Label("续接会话", systemImage: "arrow.uturn.forward.circle")
                                    }
                                }
                                // 关会话 = 结束 agent 进程并从列表移除；
                                // bridge 重启后不认识的残留行也从这里清掉
                                Button(role: .destructive) {
                                    Task {
                                        if isSelected(item.key) {
                                            selectedSession?.wrappedValue = nil
                                        }
                                        await model.closeSession(item.key)
                                    }
                                } label: {
                                    Label("关闭会话", systemImage: "xmark.circle")
                                }
                            }
                    }
                }
                .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    // MARK: - 账号额度

    /// 账号级额度（quotaProbe 闲时也在喂数据）；手表表盘同源，这里给全量窗口明细
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "额度", trailing: "账号级")
            VStack(spacing: 0) {
                ForEach(Array(model.hostQuotas.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Hairline().padding(.leading, 16)
                    }
                    quotaRow(item)
                }
            }
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func quotaRow(_ item: HostQuota) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentBadge(agent: item.quota.agent)
                if let plan = item.quota.planType, !plan.isEmpty {
                    LCChip(fontSize: 10) { Text(plan) }
                }
                Spacer()
                if model.hosts.hosts.count > 1 {
                    Text(item.hostName)
                        .font(.system(size: 11))
                        .foregroundStyle(LC.text3)
                }
            }
            ForEach(item.quota.windows) { window in
                quotaWindowRow(window)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 文字行在上、全宽进度条在下：模型专属桶的 label 可能很长
    /// （如 GPT-5.3-Codex-Spark），塞进固定窄列会竖排成一个字一行
    private func quotaWindowRow(_ window: QuotaWindow) -> some View {
        let remaining = max(0, min(100, 100 - window.usedPercent))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.label ?? windowName(mins: window.windowDurationMins) ?? "窗口")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LC.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("剩 \(remaining)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LC.text)
                if let reset = resetText(window.resetsAt) {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(LC.text3)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LC.elev2)
                    Capsule()
                        .fill(quotaColor(remaining: remaining))
                        .frame(width: geo.size.width * CGFloat(remaining) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    private func quotaColor(remaining: Int) -> Color {
        if remaining <= 10 { return LC.red }
        if remaining <= 30 { return LC.orange }
        return LC.green
    }

    /// windowDurationMins → 人读窗口名（与手表表盘同一套口径）：300 → "5h"、10080 → "周"
    private func windowName(mins: Int?) -> String? {
        guard let mins, mins > 0 else { return nil }
        if mins % 43200 == 0 { return mins == 43200 ? "月" : "\(mins / 43200)月" }
        if mins % 10080 == 0 { return mins == 10080 ? "周" : "\(mins / 10080)周" }
        if mins % 1440 == 0 { return mins == 1440 ? "日" : "\(mins / 1440)天" }
        if mins % 60 == 0 { return "\(mins / 60)h" }
        return "\(mins)m"
    }

    private func resetText(_ resetsAt: Int64?) -> String? {
        guard let resetsAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let mins = Int(date.timeIntervalSinceNow / 60)
        guard mins > 0 else { return nil }
        if mins < 60 { return "\(mins) 分钟后重置" }
        if mins < 48 * 60 { return "\(mins / 60) 小时后重置" }
        return "\(mins / 1440) 天后重置"
    }

    /// agent 过滤：一键只看某个运行时，对聚合列表生效。只给有会话的 agent 出 chip。
    private var filterChips: some View {
        let counts = Dictionary(grouping: orderedSessions, by: \.state.session.agent)
            .mapValues(\.count)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(nil, label: "全部 \(orderedSessions.count)")
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    if let count = counts[agent] {
                        filterChip(agent, label: "\(agentLabel(agent)) \(count)")
                    }
                }
            }
        }
    }

    private func filterChip(_ agent: AgentKind?, label: String) -> some View {
        let selected = filter == agent
        return Button {
            filter = agent
        } label: {
            HStack(spacing: 5) {
                if let agent {
                    Circle().fill(LC.agent(agent)).frame(width: 7, height: 7)
                }
                Text(label)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color(hex: 0x111111) : LC.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(selected ? Color(hex: 0xEAEAF0) : LC.elev2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sessionLink(_ item: AggregatedSession) -> some View {
        let selected = isSelected(item.key)
        let row = sessionRow(item, selected: selected)
        if isSelectionMode {
            Button {
                openSession(item.key)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item.key) {
                row
            }
            .buttonStyle(.plain)
        }
    }

    private func sessionRow(_ item: AggregatedSession, selected: Bool = false) -> some View {
        let state = item.state
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AgentBadge(agent: state.session.agent)
                StatusPill(style: .session(state.session.status))
                if state.isDesynced {
                    Text("流水可能不完整")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LC.orange)
                }
                Spacer()
            }
            Text(state.session.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LC.text)
                .lineLimit(1)
            if let last = state.blocks.last {
                let preview = blockPreview(last)
                Text(preview.text)
                    .font(.system(size: 13, design: preview.mono ? .monospaced : .default))
                    .foregroundStyle(LC.text2)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(metaLine(state.session)).lineLimit(1)
                // 配了多台电脑才标注归属，单主机不加视觉噪音
                if model.hosts.hosts.count > 1 {
                    LCChip(fontSize: 10) { Text(item.hostName) }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(LC.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? LC.elev2 : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(LC.blue)
                    .frame(width: 2)
                    .padding(.vertical, 10)
            }
        }
    }

    private func metaLine(_ session: AgentSession) -> String {
        var parts = [session.workspaceRoot, relativeTime(fromMs: session.updatedAtMs)]
        if let model = session.model { parts.append(model) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var emptySessionsCard: some View {
        VStack(spacing: 6) {
            Text(model.isConnected ? "没有活动会话" : "未连接到 Mac")
                .font(.system(size: 14))
                .foregroundStyle(LC.text2)
            Text(
                model.isConnected
                    ? "点 + 开一个"
                    : "在设置里添加电脑，或点上方主机芯片重连"
            )
            .font(.system(size: 12))
            .foregroundStyle(LC.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
    }

    private func approvalIcon(_ kind: ApprovalKind) -> String {
        switch kind {
        case .shellCommand: return "terminal"
        case .fileChange: return "doc.text"
        case .tool: return "wrench.and.screwdriver"
        case .permission: return "key.fill"
        }
    }
}
