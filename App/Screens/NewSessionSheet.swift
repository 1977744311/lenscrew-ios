import AgentProtocol
import LensCrewCore
import SwiftUI

/// 屏 4 · 新会话：AGENT 单选 + 工作目录 MRU + 模式，底部「开始会话」。
struct NewSessionSheet: View {
    let model: CrewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .codex
    @State private var selectedRoot: String?
    @State private var customRoot = ""
    @State private var editingCustomRoot = false
    @State private var mode: SessionMode = .default
    @FocusState private var customRootFocused: Bool

    /// 生效的工作目录：行内输入优先于 MRU 选择
    private var effectiveRoot: String {
        if editingCustomRoot {
            return customRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedRoot ?? ""
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
                    agentSection
                    rootSection
                    modeSection
                }
            }
            .scrollDismissesKeyboard(.interactively)

            LCButton(title: "开始会话", kind: .primary) {
                let root = effectiveRoot
                Task {
                    await model.createSession(agent: agent, workspaceRoot: root, mode: mode)
                }
                dismiss()
            }
            .disabled(effectiveRoot.isEmpty || !model.isConnected)
            .opacity(effectiveRoot.isEmpty || !model.isConnected ? 0.5 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(hex: 0x161618))
        .onAppear {
            if selectedRoot == nil {
                selectedRoot = model.hosts.workspaceRoots.first
            }
        }
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
    }

    /// 副行：该 agent 最近一个会话用的 model；没有就只说它跑在本机。
    /// OAuth/就绪状态没有真实探测渠道，不编。
    private func agentSub(_ kind: AgentKind) -> String {
        let lastModel = model.sessions
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

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "模式")
            HStack(spacing: 0) {
                modeSegment(.default, label: "默认")
                modeSegment(.plan, label: "计划 · 只读")
            }
            .padding(3)
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func modeSegment(_ target: SessionMode, label: String) -> some View {
        let selected = mode == target
        return Button {
            mode = target
        } label: {
            Text(label)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? LC.text : LC.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected ? LC.elev2 : .clear, in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }
}
