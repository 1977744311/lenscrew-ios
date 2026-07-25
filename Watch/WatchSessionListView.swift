import SwiftUI

/// W2 · 会话列表（根屏）：顶部「等你审批 · N」入口 + 紧凑会话行，
/// 对应 mockup 的 WatchSessionList。数据是 iPhone 推来的跨主机聚合快照，
/// >1 台 Mac 时行上带主机名。
struct WatchSessionListView: View {
    let link: WatchLink

    var body: some View {
        Group {
            if !link.hasSynced {
                waitingView
            } else if link.snapshot.sessions.isEmpty && link.snapshot.approvals.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .navigationTitle("LensCrew")
    }

    private var listView: some View {
        // 相对时间每分钟重算，不然「刚刚」会一直挂着
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ScrollView {
                LazyVStack(spacing: 5) {
                    if !link.snapshot.approvals.isEmpty {
                        approvalBanner(count: link.snapshot.approvals.count)
                    }
                    ForEach(link.snapshot.sessions) { session in
                        row(session)
                    }
                }
            }
        }
    }

    /// 「等你审批 · N」：点击直达第一条审批卡
    private func approvalBanner(count: Int) -> some View {
        NavigationLink(value: WatchRoute.approvals) {
            HStack(spacing: 4) {
                Text("等你审批 · \(count)")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LCW.orange)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(LCW.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(LCW.orange.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// 紧凑会话行：标题 + （身份点 agent · [主机 ·] 状态 · 相对时间）
    private func row(_ session: WatchSessionDTO) -> some View {
        NavigationLink(value: WatchRoute.session(session.id)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LCW.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    WatchAgentDot(agent: session.agent)
                    metaLine(session)
                        .font(.system(size: 9.5))
                        .foregroundStyle(LCW.text3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(LCW.elev, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    /// 状态段落用状态色，其余沿用 text3；Text 拼接保留分段着色
    private func metaLine(_ session: WatchSessionDTO) -> Text {
        let status = watchStatus(session.status)
        var text = Text(watchAgentLabel(session.agent))
        if link.snapshot.multiHost {
            text = text + Text(" · \(session.hostName)")
        }
        text = text + Text(" · ") + Text(status.text).foregroundStyle(status.color)
        let time = watchRelativeTime(fromMs: session.updatedAtMs)
        if !time.isEmpty {
            text = text + Text(" · \(time)")
        }
        return text
    }

    private var waitingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("等待 iPhone 同步…")
                .font(.system(size: 11))
                .foregroundStyle(LCW.text3)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 20))
                .foregroundStyle(LCW.text3)
            Text("还没有会话")
                .font(.system(size: 12, weight: .semibold))
            Text("在 iPhone 上连接 Mac 后这里会同步")
                .font(.system(size: 10))
                .foregroundStyle(LCW.text3)
                .multilineTextAlignment(.center)
        }
    }
}
