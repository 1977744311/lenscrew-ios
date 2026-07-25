import SwiftUI

@main
struct LensCrewApp: App {
    /// APNs 注册回调只走 UIKit delegate，SwiftUI 生命周期在这里开口
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// model 提到 App 级：通知管线（PushCoordinator）要在根视图之外够得着它
    @State private var model = CrewViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

enum RootTab {
    case sessions, glasses, settings
}

/// 根视图：三个 tab + 自定义 dock。
/// 不用系统 TabView 是因为 mockup 的 dock 右侧有独立的圆形 + 按钮，
/// 系统 tab bar 塞不进这种布局。
struct RootView: View {
    let model: CrewViewModel
    @State private var tab: RootTab = .sessions
    /// 会话导航栈：元素是 sessionID
    @State private var sessionPath: [String] = []
    @State private var showNewSession = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LC.bg.ignoresSafeArea()

            switch tab {
            case .sessions:
                NavigationStack(path: $sessionPath) {
                    HomeScreen(model: model, path: $sessionPath)
                        .navigationDestination(for: String.self) { sessionID in
                            SessionScreen(model: model, sessionID: sessionID)
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
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(model: model)
        }
        .preferredColorScheme(.dark)
        .tint(LC.blue)
        .task {
            // 通知管线先接上：冷启动攒下的深链与 token 都靠 attach 冲账
            PushCoordinator.shared.attach(model)
            applyPendingRoute()
            // 启动即连 active 主机；没配置过就等用户去设置页添加
            if model.hosts.active != nil {
                await model.connect()
            }
        }
        .onChange(of: model.pendingSessionRoute) { _, route in
            guard route != nil else { return }
            applyPendingRoute()
        }
    }

    /// 通知深链的落地：切到会话 tab 并把目标会话推上导航栈
    private func applyPendingRoute() {
        guard let route = model.pendingSessionRoute else { return }
        tab = .sessions
        sessionPath = [route]
        model.clearSessionRoute()
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            // mockup 的 dock-glass：模糊 + 深色罩 + 顶部发丝线
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                Color(hex: 0x0A0A0C).opacity(0.62)
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
            .foregroundStyle(active ? .white : Color(hex: 0xEBEBF5).opacity(0.34))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
