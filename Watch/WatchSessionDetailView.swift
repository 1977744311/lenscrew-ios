import SwiftUI

/// W3 · 会话详情：标题 + 状态行 + 最近块摘要 + 底部「听写追加 / 中断」，
/// 对应 mockup 的 WatchSessionDetail。听写是手表上唯一的文本输入面。
struct WatchSessionDetailView: View {
    @ObservedObject var link: WatchLink
    /// WatchSessionDTO.id（hostID#sessionID）；从快照实时解引用，随推送更新
    let sessionID: String

    private var session: WatchSessionDTO? {
        link.snapshot.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        if let session {
            content(session)
        } else {
            Text("会话已不在列表")
                .font(.system(size: 11))
                .foregroundStyle(LCW.text3)
        }
    }

    private func content(_ session: WatchSessionDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                statusLine(session)
                recentCard(session)
                actions(session)
            }
        }
    }

    private func statusLine(_ session: WatchSessionDTO) -> some View {
        let status = watchStatus(session.status)
        return HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 4.5, height: 4.5)
            statusMeta(session)
                .font(.system(size: 10))
                .lineLimit(1)
        }
    }

    private func statusMeta(_ session: WatchSessionDTO) -> Text {
        let status = watchStatus(session.status)
        var text = Text(status.text).foregroundStyle(status.color).fontWeight(.semibold)
        if link.snapshot.multiHost {
            text = text + Text(" · \(session.hostName)").foregroundStyle(LCW.text3)
        }
        let time = watchRelativeTime(fromMs: session.updatedAtMs)
        if !time.isEmpty {
            text = text + Text(" · \(time)").foregroundStyle(LCW.text3)
        }
        return text
    }

    /// 最近块摘要：iPhone 侧预渲染的 2–3 行，行间发丝线
    private func recentCard(_ session: WatchSessionDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.recentLines.isEmpty {
                Text("还没有流水")
                    .font(.system(size: 10))
                    .foregroundStyle(LCW.text3)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            } else {
                ForEach(Array(session.recentLines.enumerated()), id: \.offset) { index, line in
                    if index > 0 {
                        LCW.line.frame(height: 0.5).padding(.leading, 9)
                    }
                    Text(line.text)
                        .font(.system(size: 10, design: line.mono ? .monospaced : .default))
                        .foregroundStyle(LCW.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LCW.elev, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 听写追加指令（主）+ 中断（destructive）；动作经 iPhone 路由回对应主机
    private func actions(_ session: WatchSessionDTO) -> some View {
        HStack(spacing: 5) {
            TextFieldLink(prompt: Text("追加指令")) {
                HStack(spacing: 3) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("听写追加指令")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LCW.lightBlue)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 33)
                .background(LCW.blue.opacity(0.16), in: Capsule())
            } onSubmit: { text in
                link.sendText(text, to: session)
            }
            .buttonStyle(.plain)

            WatchCapsuleButton(
                title: "中断", kind: .destructive, icon: "stop.fill", fontSize: 10.5
            ) { link.interrupt(session) }
                .frame(width: 62)
        }
        .padding(.top, 3)
    }
}
