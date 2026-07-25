import AgentProtocol
import SwiftUI

/// W1 · 审批卡（核心屏）：一屏一事，队首优先，对应 mockup 的 WatchApproval。
/// 三档裁决完全由 approval.options 驱动（allow+once=主 / allow+session=次 / deny=弱，
/// 没有的档不显示），层级与手机 ApprovalSheet 一致；persistent 影响面太大，刻意不上腕。
/// 裁决后不乐观撤卡：等 iPhone 的下一份快照把该审批从队列里拿掉，队列空了自动退回。
struct WatchApprovalView: View {
    let link: WatchLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item = link.snapshot.approvals.first {
                card(item, total: link.snapshot.approvals.count)
            } else {
                allClearView
            }
        }
        .navigationTitle("审批")
        .onChange(of: link.snapshot.approvals.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    private func card(_ item: WatchApprovalDTO, total: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                header(item)
                detailCard(item)
                if total > 1 {
                    Text("还有 \(total - 1) 条在排队")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LCW.text3)
                }
                if link.submittedApprovalIDs.contains(item.id) {
                    submittedRow
                } else {
                    optionStack(item)
                }
            }
        }
    }

    // MARK: - 头部：人话标题 + 「会话名 · agent」

    private func header(_ item: WatchApprovalDTO) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: kindIcon(item.approval.kind))
                .font(.system(size: 12))
                .foregroundStyle(LCW.orange)
                .frame(width: 21, height: 21)
                .background(LCW.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 6.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.approval.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    WatchAgentDot(agent: item.agent)
                    Text(sessionMeta(item))
                        .font(.system(size: 9.5))
                        .foregroundStyle(LCW.text3)
                        .lineLimit(1)
                }
            }
        }
    }

    private func sessionMeta(_ item: WatchApprovalDTO) -> String {
        var meta = "\(item.sessionTitle) · \(watchAgentLabel(item.agent))"
        if link.snapshot.multiHost {
            meta += " · \(item.hostName)"
        }
        return meta
    }

    private func kindIcon(_ kind: ApprovalKind) -> String {
        switch kind {
        case .shellCommand: "terminal"
        case .fileChange: "doc.text"
        case .tool: "wrench.and.screwdriver"
        case .permission: "key.fill"
        }
    }

    // MARK: - 正文：命令 monospace 块 + 工作目录

    private func detailCard(_ item: WatchApprovalDTO) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.approval.detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(hex: 0xEAEAF0))
                .lineLimit(8)
            if let cwd = item.approval.cwd {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                    Text(cwd)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(LCW.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(LCW.elev, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(LCW.line, lineWidth: 0.5)
        )
    }

    // MARK: - 裁决按钮

    private var submittedRow: some View {
        HStack(spacing: 5) {
            ProgressView()
            Text("已发送，等 iPhone 确认…")
                .font(.system(size: 10))
                .foregroundStyle(LCW.text3)
        }
        .frame(maxWidth: .infinity, minHeight: 37)
    }

    /// persistent 之外的选项按影响面排：允许一次 > 本会话 > 拒绝 > 中断（同手机）
    private func optionStack(_ item: WatchApprovalDTO) -> some View {
        let options = item.approval.options
            .filter { $0.scope != .persistent }
            .sorted { rank($0) < rank($1) }
        return VStack(spacing: 5) {
            ForEach(options) { option in
                optionButton(option, item: item)
            }
        }
        .padding(.top, 3)
    }

    private func rank(_ option: ApprovalOption) -> Int {
        switch (option.kind, option.scope) {
        case (.allow, .once): 0
        case (.allow, _): 1
        case (.deny, _): 2
        case (.abort, _): 3
        }
    }

    @ViewBuilder
    private func optionButton(_ option: ApprovalOption, item: WatchApprovalDTO) -> some View {
        switch (option.kind, option.scope) {
        case (.allow, .once):
            WatchCapsuleButton(
                title: "允许一次", kind: .primary, icon: "checkmark",
                minHeight: 37, fontSize: 13
            ) { link.resolve(item, optionID: option.id) }
        case (.allow, _):
            WatchCapsuleButton(title: "本会话都允许", kind: .tinted) {
                link.resolve(item, optionID: option.id)
            }
        case (.deny, .once):
            WatchCapsuleButton(title: "拒绝", kind: .plain, foregroundOverride: LCW.text2) {
                link.resolve(item, optionID: option.id)
            }
        case (.deny, _):
            WatchCapsuleButton(
                title: "本会话都拒绝", kind: .plain, foregroundOverride: LCW.text2
            ) { link.resolve(item, optionID: option.id) }
        case (.abort, _):
            WatchCapsuleButton(title: "中断", kind: .plain, foregroundOverride: LCW.red) {
                link.resolve(item, optionID: option.id)
            }
        }
    }

    private var allClearView: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(LCW.green)
            Text("没有等你的审批")
                .font(.system(size: 12))
                .foregroundStyle(LCW.text2)
        }
    }
}
