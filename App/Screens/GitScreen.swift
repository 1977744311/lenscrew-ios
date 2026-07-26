import AgentProtocol
import BridgeLink
import SwiftUI

/// git 面板的呈现路由：从会话页带 (主机, 仓库) 进来。
/// workspaceRoot 是 Mac 上的绝对路径，面板内一切请求都对它发起。
struct GitRoute: Hashable, Identifiable {
    let hostID: UUID
    let workspaceRoot: String

    var id: String { "\(hostID):\(workspaceRoot)" }
}

/// git 操作面板：查看仓库状态 / diff，执行常用 git 操作。
/// 手机是控制面——能收的改动收进提交推走，收不了的（冲突、非快进）
/// 原样把 git 的话摆出来，让用户回 Mac 处理，不在手机上制造复杂状态。
struct GitScreen: View {
    let model: CrewViewModel
    let route: GitRoute
    @Environment(\.dismiss) private var dismiss

    @State private var status: GitStatusSummary?
    @State private var log: [GitLogEntry] = []
    @State private var loading = true
    /// 操作进行中：按钮全体禁用，防止并发写操作互相踩 index.lock
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var commitMessage = ""
    @State private var diffTarget: DiffTarget?
    @State private var discardCandidate: GitFileChange?
    @State private var branchPrompt = false
    @State private var newBranchName = ""
    @State private var localBranches: [String] = []

    private struct DiffTarget: Identifiable {
        let path: String?
        let staged: Bool
        var id: String { "\(staged):\(path ?? "*")" }
    }

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    if let status {
                        branchCard(status)
                        stagedSection(status)
                        unstagedSection(status)
                        commitCard(status)
                        historySection
                    } else if loading {
                        HStack {
                            Spacer()
                            ProgressView().tint(LC.text2).padding(.top, 60)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(LC.bg)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task { await reload() }
        .sheet(item: $diffTarget) { target in
            GitDiffSheet(
                model: model, route: route, path: target.path, staged: target.staged
            )
        }
        .confirmationDialog(
            "丢弃改动？", isPresented: .init(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let candidate = discardCandidate {
                Button(
                    candidate.code == "?" ? "删除 \(fileName(candidate.path))" : "丢弃对 \(fileName(candidate.path)) 的修改",
                    role: .destructive
                ) {
                    perform(.discard(root: route.workspaceRoot, paths: [candidate.path]))
                }
            }
            Button("取消", role: .cancel) { discardCandidate = nil }
        } message: {
            Text(
                discardCandidate?.code == "?"
                    ? "未跟踪的文件会被删除，无法从 git 找回。"
                    : "工作区的修改会被还原成暂存/HEAD 的内容。"
            )
        }
        .alert("新建分支", isPresented: $branchPrompt) {
            TextField("分支名", text: $newBranchName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("创建并切换") {
                let name = newBranchName.trimmingCharacters(in: .whitespaces)
                newBranchName = ""
                guard !name.isEmpty else { return }
                perform(.checkout(root: route.workspaceRoot, branch: name, create: true))
            }
            Button("取消", role: .cancel) { newBranchName = "" }
        }
    }

    // MARK: - 导航头

    private var navHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LC.elev, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName(route.workspaceRoot))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LC.text)
                    .lineLimit(1)
                Text(route.workspaceRoot)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LC.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(busy || loading ? LC.text3 : LC.text2)
                    .frame(width: 34, height: 34)
                    .background(LC.elev, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy || loading)
            .accessibilityLabel("刷新")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - 分支卡

    private func branchCard(_ status: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LC.lightBlue)
                Text(status.branch ?? "HEAD 已分离")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(status.branch == nil ? LC.orange : LC.text)
                    .lineLimit(1)
                    .accessibilityIdentifier("git.branch")
                Spacer(minLength: 8)
                if let ahead = status.ahead, let behind = status.behind {
                    LCChip(fontSize: 11.5) {
                        (Text("↑\(ahead)").foregroundStyle(ahead > 0 ? LC.green : LC.text3)
                            + Text("  ↓\(behind)").foregroundStyle(behind > 0 ? LC.orange : LC.text3))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    }
                }
                if status.stashCount > 0 {
                    LCChip(fontSize: 11.5) {
                        Image(systemName: "tray.full").font(.system(size: 10))
                        Text("\(status.stashCount)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let upstream = status.upstream {
                Text("跟踪 \(upstream)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LC.text3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                actionButton("拉取", icon: "arrow.down") {
                    perform(.pull(root: route.workspaceRoot))
                }
                actionButton(
                    "推送", icon: "arrow.up",
                    emphasized: (status.ahead ?? 0) > 0 || status.upstream == nil
                ) {
                    perform(.push(root: route.workspaceRoot))
                }
                branchMenu(status)
                stashMenu(status)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(LC.elev)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LC.line, lineWidth: 0.5))
    }

    private func actionButton(
        _ title: String, icon: String, emphasized: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(emphasized ? .white : LC.lightBlue)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                emphasized ? LC.blue : LC.blue.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// 分支切换：点开先拉本地分支列表，切换走 git switch
    private func branchMenu(_ status: GitStatusSummary) -> some View {
        Menu {
            Section("切换分支") {
                ForEach(localBranches, id: \.self) { branch in
                    Button {
                        guard branch != status.branch else { return }
                        perform(.checkout(root: route.workspaceRoot, branch: branch, create: false))
                    } label: {
                        if branch == status.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
            Button {
                branchPrompt = true
            } label: {
                Label("新建分支…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
                Text("分支").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LC.text)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(LC.elev2, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(busy)
    }

    private func stashMenu(_ status: GitStatusSummary) -> some View {
        Menu {
            Button {
                perform(.stash(root: route.workspaceRoot))
            } label: {
                Label("收起当前改动", systemImage: "tray.and.arrow.down")
            }
            .disabled(status.staged.isEmpty && status.unstaged.allSatisfy { $0.code == "?" })
            Button {
                perform(.stashPop(root: route.workspaceRoot))
            } label: {
                Label("取回最近一条", systemImage: "tray.and.arrow.up")
            }
            .disabled(status.stashCount == 0)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray").font(.system(size: 11, weight: .bold))
                Text("stash").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LC.text)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(LC.elev2, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(busy)
    }

    // MARK: - 文件分区

    private func stagedSection(_ status: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "已暂存",
                trailing: status.staged.isEmpty ? nil : "\(status.staged.count) 个文件"
            )
            if status.staged.isEmpty {
                emptyHint("暂存区是空的")
            } else {
                fileCard(status.staged, staged: true)
            }
        }
    }

    private func unstagedSection(_ status: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(
                    title: "工作区",
                    trailing: status.unstaged.isEmpty ? nil : "\(status.unstaged.count) 个文件"
                )
                if status.unstaged.count > 1 {
                    Button("全部暂存") {
                        perform(.stage(root: route.workspaceRoot, paths: []))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LC.lightBlue)
                    .disabled(busy)
                }
            }
            if status.unstaged.isEmpty {
                emptyHint("工作区没有未暂存的改动")
            } else {
                fileCard(status.unstaged, staged: false)
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(LC.text3)
            .padding(.horizontal, 4)
    }

    private func fileCard(_ changes: [GitFileChange], staged: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                fileRow(change, staged: staged)
                if index < changes.count - 1 {
                    Hairline().padding(.leading, 40)
                }
            }
        }
        .background(LC.elev)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LC.line, lineWidth: 0.5))
    }

    private func fileRow(_ change: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 10) {
            // 行主体开 diff；untracked 的"diff"由 bridge 用 --no-index 给出全新增
            Button {
                diffTarget = DiffTarget(path: change.path, staged: staged)
            } label: {
                HStack(spacing: 10) {
                    codeBadge(change.code)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(fileName(change.path))
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(LC.text)
                                .lineLimit(1)
                            lineCounts(change)
                        }
                        Text(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LC.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if staged {
                iconAction("minus.circle", tint: LC.text2, label: "取消暂存") {
                    perform(.unstage(root: route.workspaceRoot, paths: [change.path]))
                }
            } else {
                iconAction("plus.circle", tint: LC.green, label: "暂存") {
                    perform(.stage(root: route.workspaceRoot, paths: [change.path]))
                }
                iconAction("arrow.uturn.backward.circle", tint: LC.red, label: "丢弃") {
                    discardCandidate = change
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityIdentifier("git.file.\(change.path)")
    }

    /// 体量一眼可见：AI 一轮改几十个文件时，用户靠这个决定先看哪个。
    /// 拿不到（二进制/untracked/冲突）就不显示——显示 "+0 −0" 是在撒谎。
    @ViewBuilder
    private func lineCounts(_ change: GitFileChange) -> some View {
        if let added = change.added, let removed = change.removed {
            (Text("+\(added)").foregroundStyle(LC.green)
                + Text(" −\(removed)").foregroundStyle(LC.red))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func iconAction(
        _ systemName: String, tint: Color, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
    }

    /// porcelain 状态字母 → 彩色小方块
    private func codeBadge(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(badgeColor(code))
            .frame(width: 20, height: 20)
            .background(badgeColor(code).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    private func badgeColor(_ code: String) -> Color {
        switch code {
        case "A": return LC.green
        case "M", "T": return LC.orange
        case "D": return LC.red
        case "R", "C": return LC.lightBlue
        case "U": return LC.red
        default: return Color(hex: 0xEBEBF5).opacity(0.5)  // "?" untracked
        }
    }

    // MARK: - 提交卡

    private func commitCard(_ status: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "提交")
            VStack(spacing: 10) {
                TextField("提交信息…", text: $commitMessage, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(LC.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(LC.elev2.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("git.commitMessage")
                Button {
                    let message = commitMessage
                    perform(.commit(root: route.workspaceRoot, message: message)) {
                        commitMessage = ""
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().tint(.white).scaleEffect(0.8) }
                        Text(
                            status.staged.isEmpty
                                ? "提交（先暂存文件）"
                                : "提交 \(status.staged.count) 个文件"
                        )
                        .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        status.staged.isEmpty || commitTrimmed.isEmpty ? LC.elev2 : LC.blue,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy || status.staged.isEmpty || commitTrimmed.isEmpty)
                .accessibilityIdentifier("git.commit")
            }
            .padding(12)
            .background(LC.elev)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LC.line, lineWidth: 0.5))
        }
    }

    private var commitTrimmed: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 最近提交

    @ViewBuilder
    private var historySection: some View {
        if !log.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "最近提交")
                VStack(spacing: 0) {
                    ForEach(Array(log.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Text(String(entry.sha.prefix(7)))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LC.lightBlue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.subject)
                                    .font(.system(size: 13))
                                    .foregroundStyle(LC.text)
                                    .lineLimit(1)
                                Text("\(entry.author) · \(relativeTime(fromMs: entry.timeMs))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LC.text3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if index < log.count - 1 {
                            Hairline().padding(.leading, 12)
                        }
                    }
                }
                .background(LC.elev)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LC.line, lineWidth: 0.5))
            }
        }
    }

    // MARK: - 错误条

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 6)
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(LC.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LC.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("git.error")
    }

    // MARK: - 数据流

    /// status 是面板的事实源；分支列表与最近提交顺路补齐，失败不挡主面板
    private func reload() async {
        loading = status == nil
        defer { loading = false }
        do {
            let outcome = try await model.git(
                .status(root: route.workspaceRoot), on: route.hostID
            )
            if case let .status(fresh) = outcome {
                status = fresh
                errorMessage = nil
            }
        } catch {
            errorMessage = describeBridgeError(error)
            return
        }
        if case let .branches(_, local)? = try? await model.git(
            .branches(root: route.workspaceRoot), on: route.hostID
        ) {
            localBranches = local
        }
        if case let .log(entries)? = try? await model.git(
            .log(root: route.workspaceRoot, limit: 20), on: route.hostID
        ) {
            log = entries
        }
    }

    /// 写操作统一入口：串行执行 → 失败把 git 的原话贴出来 → 无论成败都刷新状态
    private func perform(_ request: GitRequest, onSuccess: @escaping () -> Void = {}) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.git(request, on: route.hostID)
                errorMessage = nil
                onSuccess()
            } catch {
                errorMessage = describeBridgeError(error)
            }
            await reload()
        }
    }
}

// MARK: - diff sheet

/// 单文件或整仓 diff，按行着色。手机上看 diff 是"确认 agent 改了什么"，
/// 不是代码评审。AI 一轮改动的 diff 动辄几千行，所以：
/// 头部先给增删统计与截断提示（不用滚到底才发现），行按需分批渲染
/// （滚多少渲多少，首屏不为万行 diff 买单），超长部分由 bridge 按行截断。
struct GitDiffSheet: View {
    let model: CrewViewModel
    let route: GitRoute
    let path: String?
    let staged: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String]?
    @State private var additions = 0
    @State private var deletions = 0
    @State private var truncated = false
    @State private var errorMessage: String?
    /// 已渲染的行数上限，滚动触底时按页递增
    @State private var visibleCount = GitDiffSheet.pageSize

    private static let pageSize = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LC.line)
            if truncated {
                truncationNotice
            }
            content
        }
        .background(LC.bg)
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 13))
                .foregroundStyle(LC.text2)
            Text(path.map(fileName) ?? "全部改动")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LC.text)
                .lineLimit(1)
            LCChip(fontSize: 11) {
                Text(staged ? "已暂存" : "工作区")
            }
            if additions > 0 || deletions > 0 {
                (Text("+\(additions)").foregroundStyle(LC.green)
                    + Text(" −\(deletions)").foregroundStyle(LC.red))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .fixedSize()
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LC.text2)
                    .frame(width: 30, height: 30)
                    .background(LC.elev, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 截断提示放在头部：滚到底才发现"不全"是最糟的体验
    private var truncationNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 11))
            Text("改动很大，只截取了前 256 KB，完整 diff 回 Mac 上看")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(LC.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(LC.orange.opacity(0.10))
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("拿不到 diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if let lines {
            if lines.isEmpty {
                ContentUnavailableView(
                    "没有差异", systemImage: "checkmark.circle",
                    description: Text(staged ? "暂存区与 HEAD 一致" : "工作区与暂存区一致")
                )
            } else {
                diffBody(lines)
            }
        } else {
            Spacer()
            ProgressView().tint(LC.text2)
            Spacer()
        }
    }

    private func diffBody(_ lines: [String]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(visibleCount).enumerated()), id: \.offset) {
                    _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Self.lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 0.5)
                        .background(Self.lineBackground(line))
                }
                if visibleCount < lines.count {
                    // 哨兵：滚到这儿就再放一页，不打断滚动也不一次全渲染
                    HStack(spacing: 6) {
                        ProgressView().tint(LC.text3).scaleEffect(0.7)
                        Text("还有 \(lines.count - visibleCount) 行")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LC.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .onAppear { visibleCount += Self.pageSize }
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    /// 着色规则：hunk 头亮蓝、增绿删红、文件头次要色
    static func lineColor(_ line: String) -> Color {
        if line.hasPrefix("@@") { return LC.lightBlue }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return LC.text2 }
        if line.hasPrefix("+") { return LC.green }
        if line.hasPrefix("-") { return LC.red }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return LC.text3 }
        return LC.text2
    }

    static func lineBackground(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return LC.green.opacity(0.08) }
        if line.hasPrefix("-") { return LC.red.opacity(0.08) }
        return .clear
    }

    private func load() async {
        do {
            let outcome = try await model.git(
                .diff(root: route.workspaceRoot, path: path, staged: staged),
                on: route.hostID
            )
            guard case let .diff(body, wasTruncated) = outcome else { return }
            // 分行与增删统计一次完成；bridge 已限流到 256KB，毫秒级
            var split: [String] = []
            var adds = 0
            var dels = 0
            for slice in body.split(separator: "\n", omittingEmptySubsequences: false) {
                if slice.hasPrefix("+"), !slice.hasPrefix("+++") {
                    adds += 1
                } else if slice.hasPrefix("-"), !slice.hasPrefix("---") {
                    dels += 1
                }
                split.append(String(slice))
            }
            if split.last == "" { split.removeLast() }
            lines = split
            additions = adds
            deletions = dels
            truncated = wasTruncated
        } catch {
            errorMessage = describeBridgeError(error)
        }
    }
}
