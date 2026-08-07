import AgentProtocol
import LensCrewCore
import SwiftUI

/// 屏 4 · 新会话：AGENT 单选 + 工作目录 MRU + 模式，底部「开始会话」。
/// 配了多台电脑时可选目标主机，创建按 hostID 路由；单台时不出这排选择。
struct NewSessionSheet: View {
    @ObservedObject var model: CrewViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var agent: AgentKind = .codex
    @State private var hostID: UUID?
    @State private var selectedRoot: String?
    @State private var customRoot = ""
    @State private var editingCustomRoot = false
    /// nil = 跟随所选 agent 的默认档
    @State private var modeID: String?
    /// nil = 跟随 CLI 默认模型
    @State private var modelID: String?
    /// nil = 跟随 CLI 默认推理档（仅所选模型自陈支持档位时展示）
    @State private var reasoningEffort: String?
    @FocusState private var customRootFocused: Bool

    private var effectiveModeID: String {
        modeID ?? AgentModes.defaultModeID(for: agent)
    }

    /// 可选模型来自该主机同 agent 最近会话的运行时自陈；
    /// 还没开过会话就没有清单，此时只能跟随 CLI 默认（会话内仍可切换）
    private var availableModels: [SessionModelOption] {
        let sessions = targetHostID.flatMap { model.link(for: $0)?.sessions } ?? []
        return sessions
            .filter { $0.session.agent == agent && !$0.session.models.isEmpty }
            .max { $0.session.updatedAtMs < $1.session.updatedAtMs }?
            .session.models ?? []
    }

    /// 所选模型自陈的推理档；未显式选模型时无从判断档位，不显示
    private var availableEfforts: [String] {
        guard let modelID else { return [] }
        return availableModels.first { $0.id == modelID }?.reasoningEfforts ?? []
    }

    /// 生效的工作目录：行内输入优先于 MRU 选择
    private var effectiveRoot: String {
        if editingCustomRoot {
            return customRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedRoot ?? ""
    }

    /// 目标主机：默认 active；只有多主机时才提供切换
    private var targetHostID: UUID? {
        hostID ?? model.hosts.activeHostID
    }

    private var targetConnected: Bool {
        guard let targetHostID else { return false }
        return model.link(for: targetHostID)?.isConnected == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("新会话")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LC.text)
                Spacer()
                Button("取消") { dismiss() }
                    .font(.system(size: 15))
                    .foregroundStyle(LC.text3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.hosts.hosts.count > 1 {
                        hostSection
                    }
                    agentSection
                    rootSection
                    modeSection
                    modelSection
                }
            }
            .scrollDismissesKeyboard(.interactively)

            LCButton(title: "开始会话", kind: .primary) {
                guard let target = targetHostID else { return }
                let root = effectiveRoot
                let chosenMode = effectiveModeID
                let chosenModel = modelID
                let chosenEffort = reasoningEffort
                Task {
                    await model.createSession(
                        agent: agent, workspaceRoot: root, modeID: chosenMode,
                        modelID: chosenModel, reasoningEffort: chosenEffort, on: target
                    )
                }
                dismiss()
            }
            .accessibilityIdentifier("newSession.start")
            .disabled(effectiveRoot.isEmpty || !targetConnected)
            .opacity(effectiveRoot.isEmpty || !targetConnected ? 0.5 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: sizeClass == .regular ? 560 : .infinity)
        .frame(maxWidth: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .lcPresentationBackground(Color(hex: 0x161618))
        .onAppear {
            if selectedRoot == nil {
                selectedRoot = model.hosts.workspaceRoots.first
            }
        }
        // 换 agent 后档位与模型集合都不同，回到新 agent 的默认
        .onChange(of: agent) { fresh in
            if let modeID, !AgentModes.options(for: fresh).contains(where: { $0.id == modeID }) {
                self.modeID = nil
            }
            modelID = nil
            reasoningEffort = nil
        }
        // 换模型后旧档位未必受支持，回到 CLI 默认
        .onChange(of: modelID) { _ in
            reasoningEffort = nil
        }
    }

    // MARK: - 电脑

    /// 会话开在哪台 Mac 上；掉线主机也可选中，但「开始会话」会被禁用
    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "电脑")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.hosts.hosts) { host in
                        hostChip(host)
                    }
                }
            }
        }
    }

    private func hostChip(_ host: BridgeHostConfig) -> some View {
        let selected = targetHostID == host.id
        let connected = model.link(for: host.id)?.isConnected == true
        return Button {
            hostID = host.id
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(connected ? LC.green : LC.text3)
                    .frame(width: 7, height: 7)
                Text(host.name)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color(hex: 0x111111) : LC.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? Color(hex: 0xEAEAF0) : LC.elev2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - AGENT

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "AGENT")
            VStack(spacing: 0) {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 {
                        Hairline().padding(.leading, 66)
                    }
                    agentRow(kind)
                }
            }
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        Button {
            agent = kind
        } label: {
            HStack(spacing: 12) {
                Text(String(agentLabel(kind).prefix(2)).lowercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(LC.agent(kind))
                    .frame(width: 38, height: 38)
                    .background(
                        LC.agent(kind).opacity(0.16), in: RoundedRectangle(cornerRadius: 11)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(agentLabel(kind))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LC.text)
                    Text(agentSub(kind))
                        .font(.system(size: 12.5))
                        .foregroundStyle(LC.text3)
                }
                Spacer()
                if agent == kind {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(LC.blue, in: Circle())
                } else {
                    Circle()
                        .strokeBorder(LC.elev2, lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newSession.agent.\(kind.rawValue)")
    }

    /// 副行：该 agent 在目标主机上最近一个会话用的 model；没有就只说它跑在本机。
    /// OAuth/就绪状态没有真实探测渠道，不编。
    private func agentSub(_ kind: AgentKind) -> String {
        let sessions = targetHostID.flatMap { model.link(for: $0)?.sessions } ?? []
        let lastModel = sessions
            .filter { $0.session.agent == kind && $0.session.model != nil }
            .max { $0.session.updatedAtMs < $1.session.updatedAtMs }?
            .session.model
        return lastModel ?? "本机运行时"
    }

    // MARK: - 工作目录

    private var rootSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "工作目录")
            VStack(spacing: 0) {
                ForEach(
                    Array(model.hosts.workspaceRoots.enumerated()), id: \.element
                ) { index, root in
                    if index > 0 {
                        Hairline().padding(.leading, 16)
                    }
                    rootRow(root)
                }
                if !model.hosts.workspaceRoots.isEmpty {
                    Hairline().padding(.leading, 16)
                }
                customRootRow
            }
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func rootRow(_ root: String) -> some View {
        let selected = !editingCustomRoot && selectedRoot == root
        return Button {
            selectedRoot = root
            editingCustomRoot = false
            customRootFocused = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? LC.text2 : LC.text3)
                Text(root)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(selected ? LC.text : LC.text2)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(LC.blue, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「输入其他路径…」：点开变行内输入，不跳页
    private var customRootRow: some View {
        Group {
            if editingCustomRoot {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(LC.text3)
                    TextField("/Users/you/project", text: $customRoot)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(LC.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($customRootFocused)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                Button {
                    editingCustomRoot = true
                    customRootFocused = true
                } label: {
                    Text("输入其他路径…")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(LC.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 模式

    /// 档位随所选 agent 变化——三家的审批/沙箱语义真实存在差异，不硬拉齐。
    /// 会话中还可以在会话页的模式 chip 上随时切换。
    private var modeSection: some View {
        let options = AgentModes.options(for: agent)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "模式")
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Hairline().padding(.leading, 16)
                    }
                    modeRow(option)
                }
            }
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - 模型

    /// 清单来自该主机同 agent 会话的运行时自陈；没开过会话就没有清单，
    /// 不显示本区（跟随 CLI 默认，会话内仍可切换）
    @ViewBuilder
    private var modelSection: some View {
        let options = availableModels
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "模型")
                Menu {
                    Button {
                        modelID = nil
                    } label: {
                        if modelID == nil {
                            Label("CLI 默认", systemImage: "checkmark")
                        } else {
                            Text("CLI 默认")
                        }
                    }
                    Section {
                        ForEach(options) { option in
                            Button {
                                modelID = option.id
                            } label: {
                                if modelID == option.id {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(
                            modelID.flatMap { id in options.first { $0.id == id }?.label }
                                ?? "CLI 默认"
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(LC.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LC.text3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
                }
                .accessibilityIdentifier("newSession.model")
                effortRow
            }
        }
    }

    /// 推理档：仅所选模型自陈支持时出现（codex）
    @ViewBuilder
    private var effortRow: some View {
        let efforts = availableEfforts
        if !efforts.isEmpty {
            Menu {
                Button {
                    reasoningEffort = nil
                } label: {
                    if reasoningEffort == nil {
                        Label("CLI 默认", systemImage: "checkmark")
                    } else {
                        Text("CLI 默认")
                    }
                }
                Section {
                    ForEach(efforts, id: \.self) { effort in
                        Button {
                            reasoningEffort = effort
                        } label: {
                            if reasoningEffort == effort {
                                Label(effort, systemImage: "checkmark")
                            } else {
                                Text(effort)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("推理程度")
                        .font(.system(size: 14))
                        .foregroundStyle(LC.text2)
                    Spacer()
                    Text(reasoningEffort ?? "CLI 默认")
                        .font(.system(size: 14))
                        .foregroundStyle(LC.text)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LC.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))
            }
            .accessibilityIdentifier("newSession.effort")
        }
    }

    private func modeRow(_ option: SessionModeOption) -> some View {
        let selected = effectiveModeID == option.id
        let dangerous = AgentModes.isDangerous(option.id)
        return Button {
            modeID = option.id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(dangerous ? LC.red : LC.text)
                    Text(option.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(LC.text3)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(dangerous ? LC.red : LC.blue, in: Circle())
                } else {
                    Circle()
                        .strokeBorder(LC.elev2, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newSession.mode.\(option.id)")
    }
}
