import AgentProtocol
import SwiftUI

/// 审批 sheet 的入参：会话上下文 + 请求本体。
/// 携带复合键，裁决按所属主机路由（会话 id 跨主机会撞号）。
struct ApprovalPresentation: Identifiable {
    let sessionKey: SessionKey
    let sessionTitle: String
    let agent: AgentKind
    let approval: ApprovalRequest

    var id: String { approval.id }
}

/// 屏 3 · 审批：半屏 sheet。按钮栈完全由 approval.options 驱动、按影响面排强弱，
/// persistent 选项刻意弱化成底部小字行。裁决后不乐观撤卡——
/// 等 approvalSettled 让 pendingApprovals 变空，由会话页把 sheet 收掉。
struct ApprovalSheet: View {
    @ObservedObject var model: CrewViewModel
    let presentation: ApprovalPresentation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var submittedOptionID: String?

    private var approval: ApprovalRequest { presentation.approval }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            detailCard
            if let cwd = approval.cwd {
                cwdRow(cwd)
            }
            optionButtons
            if let persistent = persistentOptions.first {
                persistentRow(persistent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: sizeClass == .regular ? 560 : .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .lcPresentationBackground(Color(hex: 0x161618))
        .interactiveDismissDisabled(submittedOptionID != nil)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kindIcon)
                .font(.system(size: 20))
                .foregroundStyle(LC.orange)
                .frame(width: 42, height: 42)
                .background(LC.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LC.text)
                    .lineLimit(2)
                    .accessibilityIdentifier("approval.title")
                Text(
                    "\(presentation.sessionTitle) · \(agentLabel(presentation.agent))"
                        + " · 不在自动放行名单"
                )
                .font(.system(size: 12.5))
                .foregroundStyle(LC.text3)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var kindIcon: String {
        switch approval.kind {
        case .shellCommand: return "terminal"
        case .fileChange: return "doc.text"
        case .tool: return "wrench.and.screwdriver"
        case .permission: return "key.fill"
        }
    }

    // MARK: - 正文

    private var detailCard: some View {
        ScrollView {
            Text(approval.detail)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(Color(hex: 0xEAEAF0))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
        }
        .frame(maxHeight: 140)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(LC.line, lineWidth: 0.5)
        )
        .accessibilityIdentifier("approval.detail")
    }

    private func cwdRow(_ cwd: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11))
            Text("工作目录")
            Text(cwd)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LC.text3)
    }

    // MARK: - 裁决按钮

    /// persistent 之外的选项按影响面排：允许一次 > 本会话 > 拒绝 > 中断
    private var rankedOptions: [ApprovalOption] {
        approval.options
            .filter { $0.scope != .persistent }
            .sorted { rank($0) < rank($1) }
    }

    private var persistentOptions: [ApprovalOption] {
        approval.options.filter { $0.scope == .persistent }
    }

    private func rank(_ option: ApprovalOption) -> Int {
        switch (option.kind, option.scope) {
        case (.allow, .once): return 0
        case (.allow, _): return 1
        case (.deny, _): return 2
        case (.abort, _): return 3
        }
    }

    private var optionButtons: some View {
        VStack(spacing: 9) {
            if submittedOptionID != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待 bridge 确认…")
                        .font(.system(size: 13))
                        .foregroundStyle(LC.text3)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ForEach(rankedOptions) { option in
                    optionButton(option)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func optionButton(_ option: ApprovalOption) -> some View {
        switch (option.kind, option.scope) {
        case (.allow, .once):
            LCButton(title: "允许一次", kind: .primary, icon: "checkmark") {
                submit(option)
            }
            .accessibilityIdentifier("approval.allowOnce")
        case (.allow, _):
            LCButton(title: "本会话内都允许", kind: .tinted) { submit(option) }
        case (.deny, .once):
            LCButton(title: "拒绝", kind: .plain, foregroundOverride: LC.text2) {
                submit(option)
            }
        case (.deny, _):
            LCButton(title: "本会话内都拒绝", kind: .plain, foregroundOverride: LC.text2) {
                submit(option)
            }
        case (.abort, _):
            LCButton(title: "中断", kind: .plain, foregroundOverride: LC.red) {
                submit(option)
            }
        }
    }

    /// 影响面最大的选项刻意最不显眼（mockup 的原话），点它同样走正规裁决
    private func persistentRow(_ option: ApprovalOption) -> some View {
        Button {
            submit(option)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(
                    option.kind == .allow
                        ? "永久放行此类命令并写进规则…"
                        : "永久拒绝此类命令并写进规则…"
                )
            }
            .font(.system(size: 12.5))
            .foregroundStyle(LC.text3)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(submittedOptionID != nil)
    }

    private func submit(_ option: ApprovalOption) {
        submittedOptionID = option.id
        Task {
            await model.resolve(
                approval: approval, in: presentation.sessionKey, optionID: option.id
            )
        }
    }
}
