import BridgeLink
import SwiftUI

/// 屏 6 · 设置：电脑（多主机）/ 安全 / 通知 / 关于。
/// 用 List 而不是手搓卡片，是为了白拿滑动删除；行内样式仍按 mockup 的 SetRow。
struct SettingsScreen: View {
    let model: CrewViewModel
    @State private var showAddComputer = false
    @State private var showTokenEditor = false
    @State private var tokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(LC.text)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            List {
                computersSection
                securitySection
                notificationsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 52)
            .contentMargins(.bottom, 100, for: .scrollContent)
        }
        .background(LC.bg)
        .sheet(isPresented: $showAddComputer) {
            AddComputerSheet(model: model)
        }
        .alert("访问口令", isPresented: $showTokenEditor) {
            SecureField("lenscrew up 打印的口令", text: $tokenDraft)
            Button("保存") {
                guard let host = model.hosts.active else { return }
                let token = tokenDraft
                tokenDraft = ""
                Task { await model.updateToken(token, for: host.id) }
            }
            Button("取消", role: .cancel) { tokenDraft = "" }
        } message: {
            Text("替换当前电脑「\(model.hosts.active?.name ?? "")」的口令。")
        }
    }

    // MARK: - 电脑

    private var computersSection: some View {
        Section {
            ForEach(model.hosts.hosts) { host in
                hostRow(host)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            Task { await model.removeHost(host.id) }
                        }
                    }
            }
            Button {
                showAddComputer = true
            } label: {
                SetRow(
                    icon: "qrcode.viewfinder", tint: LC.green,
                    title: "添加电脑…",
                    detail: "在 Mac 上跑 lenscrew up，扫码即配对"
                ) {
                    chevron
                }
            }
            .buttonStyle(.plain)
        } header: {
            sectionHeader("电脑")
        }
        .listRowBackground(LC.elev)
        .listRowSeparatorTint(LC.line)
    }

    private func hostRow(_ host: BridgeHostConfig) -> some View {
        let isActive = host.id == model.hosts.activeHostID
        return SetRow(
            icon: "laptopcomputer",
            tint: isActive ? LC.lightBlue : Color(hex: 0xEBEBF5).opacity(0.45),
            title: host.name,
            detail: hostDetail(host)
        ) {
            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(LC.blue, in: Circle())
            } else {
                Button("切换") {
                    Task { await model.switchHost(to: host.id) }
                }
                .font(.system(size: 12))
                .foregroundStyle(LC.text3)
                .buttonStyle(.plain)
            }
        }
    }

    /// 多连接常驻：每台主机都显示自己那条连接的实时状态，不再只有 active 有
    private func hostDetail(_ host: BridgeHostConfig) -> String {
        if let link = model.link(for: host.id) {
            switch link.linkState {
            case .connected:
                var parts = ["在线"]
                if let ms = link.latencyMs { parts.append("\(ms)ms") }
                if let path = link.linkPath { parts.append(path.label) }
                parts.append("\(link.sessions.count) 个会话")
                return parts.joined(separator: " · ")
            case .connecting:
                return "连接中…"
            case .disconnected, .failed:
                break
            }
        }
        if let last = host.lastConnectedAt {
            return "上次连接 \(relativeTime(fromMs: Int64(last.timeIntervalSince1970 * 1000)))"
        }
        return "未连接"
    }

    // MARK: - 安全

    private var securitySection: some View {
        Section {
            Button {
                showTokenEditor = true
            } label: {
                SetRow(
                    icon: "key.fill", tint: LC.orange,
                    title: "访问口令",
                    detail: "已存入 Keychain · 仅本机 · 不进 iCloud"
                ) {
                    chevron
                }
            }
            .buttonStyle(.plain)
            // paired 主机没有口令概念，凭 Keychain 里的身份密钥重连
            .disabled(model.hosts.active == nil || model.hosts.active?.isPaired == true)

            SetRow(
                icon: "checkmark.shield.fill", tint: LC.green,
                title: "端到端加密",
                detail: pairedCount > 0
                    ? "已配对 \(pairedCount) 台 · X25519+AES-GCM"
                    : "二维码配对 + E2EE 通道"
            ) {
                if pairedCount == 0 {
                    Text("开发中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LC.lightBlue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(LC.blue.opacity(0.14), in: Capsule())
                }
            }
        } header: {
            sectionHeader("安全")
        }
        .listRowBackground(LC.elev)
        .listRowSeparatorTint(LC.line)
    }

    private var pairedCount: Int {
        model.hosts.hosts.filter(\.isPaired).count
    }

    // MARK: - 通知

    /// 先落偏好；推送链路（APNs/本地通知）后续任务接
    private var notificationsSection: some View {
        Section {
            SetRow(
                icon: "bell.fill", tint: LC.red,
                title: "审批到达时推送",
                detail: "锁屏可直接批准或拒绝"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.notifyOnApproval },
                        set: { model.setNotifyOnApproval($0) }
                    )
                )
                .labelsHidden()
                .tint(LC.green)
            }
            SetRow(
                icon: "bell.fill", tint: Color(hex: 0xEBEBF5).opacity(0.45),
                title: "轮次完成时推送", detail: nil
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.notifyOnTurnCompleted },
                        set: { model.setNotifyOnTurnCompleted($0) }
                    )
                )
                .labelsHidden()
                .tint(LC.green)
            }
        } header: {
            sectionHeader("通知")
        }
        .listRowBackground(LC.elev)
        .listRowSeparatorTint(LC.line)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            SetRow(
                icon: "info.circle", tint: Color(hex: 0xEBEBF5).opacity(0.45),
                title: aboutTitle,
                detail: "bridge 契约 v1 · DAT 0.8.0"
            ) {
                EmptyView()
            }
        } header: {
            sectionHeader("关于")
        }
        .listRowBackground(LC.elev)
        .listRowSeparatorTint(LC.line)
    }

    private var aboutTitle: String {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "LensCrew \($0)" } ?? "LensCrew"
    }

    // MARK: - 小件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LC.text2)
            .textCase(nil)
            .accessibilityIdentifier("settings.section.\(title)")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(LC.text3)
    }
}

/// mockup 的 SetRow：30pt 圆角图标块 + 标题 + 副行 + 右侧元素
private struct SetRow<Right: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(LC.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(LC.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            right
        }
        .padding(.vertical, 2)
    }
}

/// 添加电脑：扫码配对（E2EE）或手动填配置（明文 HTTP + 口令）。
private struct AddComputerSheet: View {
    let model: CrewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var name = ""
    @State private var host = ""
    @State private var portText = "\(BridgeHostConfig.defaultPort)"
    @State private var token = ""

    private var port: Int? { Int(portText) }

    private var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && (port ?? 0) > 0
            && !token.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("添加电脑")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(LC.text)
                Spacer()
                Button("取消") { dismiss() }
                    .font(.system(size: 15))
                    .foregroundStyle(LC.text3)
            }

            Button {
                showScanner = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 16))
                    Text("扫码配对").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(LC.lightBlue)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(LC.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                field("名称", text: $name, placeholder: "书房的 Mac mini")
                Hairline().padding(.leading, 16)
                field("主机", text: $host, placeholder: "192.168.1.20", keyboard: .URL)
                Hairline().padding(.leading, 16)
                field("端口", text: $portText, placeholder: "4311", keyboard: .numberPad)
                Hairline().padding(.leading, 16)
                HStack(spacing: 12) {
                    Text("口令")
                        .font(.system(size: 14))
                        .foregroundStyle(LC.text2)
                        .frame(width: 42, alignment: .leading)
                    SecureField("lenscrew up 会打印", text: $token)
                        .font(.system(size: 14))
                        .foregroundStyle(LC.text)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(LC.elev, in: RoundedRectangle(cornerRadius: 20))

            Text("在 Mac 上跑 lenscrew up --host 0.0.0.0，它会打印地址和口令。")
                .font(.system(size: 12))
                .foregroundStyle(LC.text3)
                .padding(.horizontal, 4)

            Spacer(minLength: 0)

            LCButton(title: "保存", kind: .primary) {
                guard let port else { return }
                let config = model.hosts.add(
                    name: name.trimmingCharacters(in: .whitespaces),
                    host: host.trimmingCharacters(in: .whitespaces),
                    port: port,
                    token: token
                )
                dismiss()
                // 多连接常驻：新主机保存即入列连接，不打断其他主机的连接
                Task { await model.connectHost(config.id) }
            }
            .disabled(!isComplete)
            .opacity(isComplete ? 1 : 0.5)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(hex: 0x161618))
        .fullScreenCover(isPresented: $showScanner) {
            PairingScanView(model: model) {
                // 配对成功：收掉扫码页和本 sheet，回设置页看新主机行
                showScanner = false
                dismiss()
            }
        }
    }

    private func field(
        _ label: String, text: Binding<String>, placeholder: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(LC.text2)
                .frame(width: 42, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .foregroundStyle(LC.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
