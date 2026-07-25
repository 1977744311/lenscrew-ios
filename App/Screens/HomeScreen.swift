import AgentProtocol
import BridgeLink
import LensCrewCore
import SwiftUI

/// 屏 1 · 指挥台：跨主机合并的审批队列置顶 + 全部主机会话按最近活动统一排序。
struct HomeScreen: View {
    let model: CrewViewModel
    @Binding var path: [SessionKey]
    @State private var filter: AgentKind?
    /// 已发出裁决、还没等到 approvalSettled 的审批：期间禁用按钮防止重复提交，
    /// 但卡不撤——撤卡的唯一依据是 bridge 的结清事件。键是 hostID#approvalID。
    @State private var resolvingApprovals: Set<String> = []

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
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 4)
        }
        .background(LC.bg)
        .toolbar(.hidden, for: .navigationBar)
        .contentMargins(.bottom, 100, for: .scrollContent)
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
                    path.append(item.key)
                }
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
                        NavigationLink(value: item.key) {
                            sessionRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
            }
        }
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

    private func sessionRow(_ item: AggregatedSession) -> some View {
        let state = item.state
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AgentBadge(agent: state.session.agent)
                StatusPill(style: .session(state.session.status))
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
                    ? "点右下角 + 开一个"
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
