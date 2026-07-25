import AgentProtocol
import LensCrewCore
import SwiftUI

struct SessionScreen: View {
    @State var model: CrewViewModel
    let sessionID: String
    @State private var draft = ""

    private var state: SessionState? {
        model.sessions.first { $0.session.id == sessionID }
    }

    var body: some View {
        Group {
            if let state {
                content(state)
            } else {
                ContentUnavailableView("会话已结束", systemImage: "xmark.circle")
            }
        }
        .navigationTitle(state?.session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ state: SessionState) -> some View {
        VStack(spacing: 0) {
            // 审批置顶：agent 卡在这里等人，别的都得让路
            if let approval = state.pendingApprovals.first {
                ApprovalBanner(approval: approval) { optionID in
                    Task {
                        await model.resolve(
                            approval: approval, in: sessionID, optionID: optionID
                        )
                    }
                }
            }
            transcript(state)
            composer(state)
        }
    }

    private func transcript(_ state: SessionState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.blocks, id: \.id) { block in
                        BlockView(block: block).id(block.id)
                    }
                }
                .padding()
            }
            .onChange(of: state.blocks.count) {
                guard let last = state.blocks.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func composer(_ state: SessionState) -> some View {
        HStack(spacing: 8) {
            TextField("说点什么…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            if state.session.status == .running {
                Button {
                    Task { await model.interrupt(sessionID) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("中断")
            }
            Button {
                let text = draft
                draft = ""
                Task { await model.send(text, to: sessionID) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("发送")
        }
        .padding()
        .background(.bar)
    }
}

private struct ApprovalBanner: View {
    let approval: ApprovalRequest
    let resolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(approval.detail)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            // 作用范围直接写进按钮，不让用户靠文案猜影响面
            ForEach(approval.options) { option in
                Button {
                    resolve(option.id)
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        Text(scopeLabel(option.scope))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .tint(tint(option.kind, option.scope))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func scopeLabel(_ scope: ApprovalScope) -> String {
        switch scope {
        case .once: return "仅这一次"
        case .session: return "本会话内"
        case .persistent: return "永久写进规则"
        }
    }

    /// 影响面越大越不显眼：永久放行不该和"就这一次"长得一样好按
    private func tint(_ kind: ApprovalOptionKind, _ scope: ApprovalScope) -> Color {
        switch (kind, scope) {
        case (.allow, .once): return .green
        case (.allow, _): return .orange
        case (.deny, _), (.abort, _): return .secondary
        }
    }
}

private struct BlockView: View {
    let block: TranscriptBlock

    var body: some View {
        switch block {
        case let .userMessage(_, text, _):
            labelled("你", text: text, color: .accentColor)
        case let .agentMessage(_, text, streaming):
            labelled("Agent", text: text + (streaming ? "▍" : ""), color: .primary)
        case let .reasoning(_, text, streaming):
            labelled("思考", text: text + (streaming ? "▍" : ""), color: .secondary)
        case let .shellCommand(_, command, _, output, exitCode, status):
            VStack(alignment: .leading, spacing: 4) {
                Text("$ \(command)")
                    .font(.system(.footnote, design: .monospaced))
                    .bold()
                if !output.isEmpty {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(statusText(status, exitCode: exitCode))
                    .font(.caption2)
                    .foregroundStyle(status == .failed ? .red : .secondary)
            }
        case let .fileChange(_, files, status):
            VStack(alignment: .leading, spacing: 4) {
                Text("改动 \(files.count) 个文件 · \(statusText(status, exitCode: nil))")
                    .font(.footnote).bold()
                ForEach(files, id: \.path) { file in
                    Text(diffLine(file))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        case let .toolCall(_, source, tool, summary, output, status):
            VStack(alignment: .leading, spacing: 4) {
                Text(source.map { "\($0) · \(tool)" } ?? tool)
                    .font(.footnote).bold()
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if !output.isEmpty {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }
                Text(statusText(status, exitCode: nil))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case let .plan(_, steps):
            VStack(alignment: .leading, spacing: 4) {
                Text("计划").font(.footnote).bold()
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text("\(marker(step.status)) \(step.text)").font(.caption)
                }
            }
        case let .error(_, message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func labelled(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(color).textSelection(.enabled)
        }
    }

    /// 行数拿不到时不显示 "+0 −0"——那是在撒谎
    private func diffLine(_ file: FileChangeSummary) -> String {
        guard let added = file.added, let removed = file.removed else { return file.path }
        return "\(file.path)  +\(added) −\(removed)"
    }

    private func statusText(_ status: BlockStatus, exitCode: Int?) -> String {
        let base: String
        switch status {
        case .pending: base = "等待中"
        case .running: base = "运行中"
        case .ok: base = "完成"
        case .failed: base = "失败"
        case .rejected: base = "已拒绝"
        }
        guard let exitCode else { return base }
        return "\(base) · 退出码 \(exitCode)"
    }

    private func marker(_ status: PlanStep.Status) -> String {
        switch status {
        case .pending: return "·"
        case .running: return "▸"
        case .done: return "✓"
        }
    }
}
