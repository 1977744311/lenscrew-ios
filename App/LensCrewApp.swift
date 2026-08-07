import SwiftUI

@main
struct LensCrewApp: App {
    /// APNs 注册回调只走 UIKit delegate，SwiftUI 生命周期在这里开口
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// model 提到 App 级：通知管线（PushCoordinator）要在根视图之外够得着它
    @StateObject private var model = CrewViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

enum RootTab {
    case sessions, glasses, settings
}

/// 根视图：按 horizontalSizeClass 分支。
/// Compact（iPhone / 窄分屏）保留底部 TabDock + NavigationStack push；
/// Regular（iPad 全屏 / 宽分屏）用顶栏切 tab + 会话侧栏分栏，不做手机缩放。
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var model: CrewViewModel
    @State private var tab: RootTab = .sessions
    /// Compact：会话 push 栈（hostID, sessionID）
    @State private var sessionPath: [SessionKey] = []
    /// Regular：分栏选中会话
    @State private var selectedSession: SessionKey?
    @State private var showNewSession = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isRegular {
                regularRoot
            } else {
                compactRoot
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(model: model)
        }
        .tint(LC.blue)
        .task {
            // 通知管线先接上：冷启动攒下的深链与 token 都靠 attach 冲账。
            // UI 夹具下跳过——requestAuthorization 的系统弹窗会卡住 XCUITest。
            if !UITestFixture.isActive {
                PushCoordinator.shared.attach(model)
            }
            // 手表中转：把聚合审批/会话推上腕、接回裁决（手表不直连 bridge）
            WatchBridge.shared.attach(model)
            applyPendingRoute()
            // 启动即连全部已配置主机；没配置过就等用户去设置页添加
            if model.hosts.active != nil {
                await model.connectAll()
            }
        }
        .onChange(of: model.pendingSessionRoute) { route in
            guard route != nil else { return }
            applyPendingRoute()
        }
        // 眼镜跟随：点进哪个会话，真实眼镜就交给它所属的主机
        .onChange(of: sessionPath) { path in
            guard let key = path.last else { return }
            Task { await model.focusHost(key.hostID) }
        }
        .onChange(of: selectedSession) { key in
            guard let key else { return }
            Task { await model.focusHost(key.hostID) }
        }
    }

    // MARK: - Compact（手机 / 窄分屏）

    private var compactRoot: some View {
        ZStack(alignment: .bottom) {
            LC.bg.ignoresSafeArea()

            switch tab {
            case .sessions:
                NavigationStack(path: $sessionPath) {
                    HomeScreen(model: model, path: $sessionPath)
                        .navigationDestination(for: SessionKey.self) { key in
                            SessionScreen(model: model, sessionKey: key)
                        }
                }
            case .glasses:
                GlassesScreen(model: model)
            case .settings:
                SettingsScreen(model: model)
            }

            // 进了会话页就让位给 composer，dock 只在三个根屏出现
            if sessionPath.isEmpty {
                TabDock(tab: $tab) { showNewSession = true }
            }
        }
    }

    // MARK: - Regular（iPad）

    private var regularRoot: some View {
        VStack(spacing: 0) {
            PadTabChrome(tab: $tab) { showNewSession = true }
            Group {
                switch tab {
                case .sessions:
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        HomeScreen(
                            model: model,
                            path: $sessionPath,
                            selectedSession: $selectedSession,
                            showsDockClearance: false
                        )
                    } detail: {
                        if let key = selectedSession {
                            SessionScreen(model: model, sessionKey: key)
                        } else {
                            emptySessionDeck
                        }
                    }
                case .glasses:
                    GlassesScreen(model: model, showsDockClearance: false)
                case .settings:
                    SettingsScreen(model: model, showsDockClearance: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LC.bg.ignoresSafeArea())
    }

    private var emptySessionDeck: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(LC.text3)
            Text("选择一个会话")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LC.text2)
            if model.pendingApprovalItems.isEmpty {
                Text("从左侧列表打开，或点 + 新建")
                    .font(.system(size: 14))
                    .foregroundStyle(LC.text3)
            } else {
                Text("有 \(model.pendingApprovalItems.count) 项待审批 · 可在左侧查看上下文")
                    .font(.system(size: 14))
                    .foregroundStyle(LC.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LC.bg)
    }

    /// 通知深链落地：切到会话 tab；regular 设选中，compact 推入导航栈
    private func applyPendingRoute() {
        guard let route = model.pendingSessionRoute else { return }
        tab = .sessions
        if isRegular {
            selectedSession = route
            sessionPath = []
        } else {
            sessionPath = [route]
        }
        model.clearSessionRoute()
    }
}

/// iPad 顶栏：三个 tab + 右侧新建，替代手机底栏 dock
private struct PadTabChrome: View {
    @Binding var tab: RootTab
    let newSession: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            tabItem(.sessions, label: "会话", icon: "bubble.left.and.bubble.right")
            tabItem(.glasses, label: "眼镜", icon: "eyeglasses")
            tabItem(.settings, label: "设置", icon: "gearshape")
            Spacer(minLength: 12)
            Button(action: newSession) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LC.blue, in: Circle())
                    .shadow(color: LC.blue.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新会话")
            .accessibilityIdentifier("dock.newSession")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.ultraThinMaterial)
                LC.dockScrim
                Hairline()
            }
        }
    }

    private func tabItem(_ target: RootTab, label: String, icon: String) -> some View {
        let active = tab == target
        return Button {
            tab = target
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 14, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? .white : LC.text3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(active ? LC.blue : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(String(describing: target))")
    }
}

/// 底部 dock：三个 tab + 右侧独立蓝色圆形 + 按钮，毛玻璃背景
private struct TabDock: View {
    @Binding var tab: RootTab
    let newSession: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 0) {
                tabItem(.sessions, label: "会话", icon: "bubble.left.and.bubble.right")
                tabItem(.glasses, label: "眼镜", icon: "eyeglasses")
                tabItem(.settings, label: "设置", icon: "gearshape")
            }
            Button(action: newSession) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LC.blue, in: Circle())
                    .shadow(color: LC.blue.opacity(0.4), radius: 9, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新会话")
            .accessibilityIdentifier("dock.newSession")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            // mockup 的 dock-glass：模糊 + 罩色 + 顶部发丝线
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                LC.dockScrim
                Hairline()
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabItem(_ target: RootTab, label: String, icon: String) -> some View {
        let active = tab == target
        return Button {
            tab = target
        } label: {
            VStack(spacing: 3) {
                // 统一图标盒高度：眼镜图标是 2:1 宽高比，不包一层会把文字顶歪
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(label)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(active ? LC.text : LC.text3)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(String(describing: target))")
    }
}
