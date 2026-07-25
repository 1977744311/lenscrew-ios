import AgentProtocol
import GlassRenderer
import GlassesKit
import LensCrewCore
import SwiftUI

struct HomeScreen: View {
    @State var model: CrewViewModel

    var body: some View {
        NavigationStack {
            List {
                glassesSection
                sessionsSection
                if let error = model.lastError {
                    Section("最近一次故障") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("LensCrew")
        }
    }

    private var glassesSection: some View {
        Section("眼镜") {
            LabeledContent("会话", value: describe(model.glassesState))
            LabeledContent("显示", value: describe(model.displayState))
            LabeledContent("当前屏", value: describe(model.screen))
            if model.usingMockGlasses {
                Text("模拟器环境，使用 Mock 眼镜会话")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("连接并挂载显示") {
                Task { await model.connectGlasses() }
            }
            Button("断开", role: .destructive) {
                Task { await model.disconnectGlasses() }
            }
        }
    }

    private var sessionsSection: some View {
        Section("会话") {
            if model.sessions.isEmpty {
                Text("没有活动会话")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sessions, id: \.session.id) { state in
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.session.title)
                        .font(.headline)
                    Text(
                        "\(state.session.agent.rawValue) · \(state.session.status.rawValue)"
                            + " · \(state.blocks.count) 条流水"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !state.pendingApprovals.isEmpty {
                        Text("待审批 \(state.pendingApprovals.count)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Button("播放演示事件流") {
                Task { await model.playDemoFeed() }
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
