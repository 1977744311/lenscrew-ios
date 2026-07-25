import AgentProtocol
import BridgeLink
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

struct HomeScreen: View {
    @State var model: CrewViewModel
    @State private var newSessionAgent: AgentKind = .codex
    @State private var newSessionRoot = ""

    var body: some View {
        NavigationStack {
            List {
                bridgeSection
                if model.isConnected {
                    sessionsSection
                    newSessionSection
                }
                glassesSection
                if let error = model.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("最近一次错误")
                    }
                }
            }
            .navigationTitle("LensCrew")
        }
    }

    // MARK: - bridge

    private var bridgeSection: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(linkColor)
                        .frame(width: 8, height: 8)
                    Text(linkText)
                }
            }
            if !model.isConnected {
                TextField("主机（Mac 的局域网地址）", text: $model.settings.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField(
                    "端口",
                    value: $model.settings.port,
                    format: .number.grouping(.never)
                )
                .keyboardType(.numberPad)
                SecureField("口令（lenscrew up 会打印）", text: $model.settings.token)
                Button("连接") {
                    Task { await model.connect() }
                }
                .disabled(!model.settings.isComplete)
            } else {
                Button("断开", role: .destructive) {
                    Task { await model.disconnect() }
                }
            }
        } header: {
            Text("bridge")
        } footer: {
            if !model.isConnected {
                Text("在 Mac 上跑 `lenscrew up --host 0.0.0.0`，它会打印地址和口令。")
            }
        }
    }

    private var linkText: String {
        switch model.linkState {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case let .failed(message): return "失败：\(message)"
        }
    }

    private var linkColor: Color {
        switch model.linkState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    // MARK: - 会话

    private var sessionsSection: some View {
        Section("会话") {
            if model.sessions.isEmpty {
                Text("没有活动会话")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sessions, id: \.session.id) { state in
                NavigationLink {
                    SessionScreen(model: model, sessionID: state.session.id)
                } label: {
                    SessionRow(state: state)
                }
            }
        }
    }

    private var newSessionSection: some View {
        Section("新建会话") {
            Picker("Agent", selection: $newSessionAgent) {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    Text(agentLabel(agent)).tag(agent)
                }
            }
            TextField(BridgeSettings.placeholderRoot, text: $newSessionRoot)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !model.settings.workspaceRoots.isEmpty {
                Menu("用最近的目录") {
                    ForEach(model.settings.workspaceRoots, id: \.self) { root in
                        Button(root) { newSessionRoot = root }
                    }
                }
                .font(.footnote)
            }
            Button("开一个") {
                let root = newSessionRoot
                Task { await model.createSession(agent: newSessionAgent, workspaceRoot: root) }
            }
            .disabled(newSessionRoot.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - 眼镜

    private var glassesSection: some View {
        Section {
            LabeledContent("会话", value: describe(model.glassesState))
            LabeledContent("显示", value: describe(model.displayState))
            LabeledContent("当前屏", value: describe(model.glassScreen))
            Button("连接并挂载显示") {
                Task { await model.connectGlasses() }
            }
            Button("断开眼镜", role: .destructive) {
                Task { await model.disconnectGlasses() }
            }
        } header: {
            Text("眼镜")
        } footer: {
            if model.usingMockGlasses {
                Text("模拟器环境，使用 Mock 眼镜会话。")
            }
        }
    }

    private func describe(_ state: GlassesSessionState) -> String {
        switch state {
        case .idle: return "空闲"
        case .starting: return "启动中"
        case .started: return "已连接"
        case .paused: return "被抢占"
        case .stopping: return "停止中"
        case .stopped: return "已停止"
        }
    }

    private func describe(_ state: GlassesKit.DisplayState) -> String {
        switch state {
        case .stopped: return "未挂载"
        case .starting: return "挂载中"
        case .started: return "已挂载"
        case .stopping: return "卸载中"
        }
    }

    private func describe(_ screen: GlassScreen) -> String {
        switch screen {
        case .sessionList: return "会话列表"
        case let .transcript(_, page, following):
            return "流水 第 \(page + 1) 页\(following ? " · 跟随" : "")"
        case .blockDetail: return "详情"
        case .approval: return "审批卡"
        }
    }
}

struct SessionRow: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.session.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(agentLabel(state.session.agent))
                Text("·")
                Text(statusLabel(state.session.status))
                if !state.pendingApprovals.isEmpty {
                    Text("· 待审批 \(state.pendingApprovals.count)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

func agentLabel(_ agent: AgentKind) -> String {
    switch agent {
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .cursor: return "Cursor"
    }
}

func statusLabel(_ status: SessionStatus) -> String {
    switch status {
    case .starting: return "启动中"
    case .idle: return "空闲"
    case .running: return "运行中"
    case .awaitingApproval: return "待审批"
    case .error: return "出错"
    case .ended: return "已结束"
    }
}
