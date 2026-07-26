import AgentProtocol

/// 各 agent 创建会话时可选的模式档位。
///
/// 事实源是 bridge 各 adapter 的静态自陈（bridge/src/adapters/*/adapter.ts 的
/// *_MODES 常量），这份表只服务"会话建立前 UI 要展示什么"；会话建立后一律以
/// bridge 快照的 session.modes 为准——cursor 甚至是运行时自陈，上游加档自动跟上。
enum AgentModes {
    static func options(for agent: AgentKind) -> [SessionModeOption] {
        switch agent {
        case .codex:
            return [
                SessionModeOption(
                    id: "plan", label: "计划 · 只读",
                    detail: "只读沙箱，能读能想，不改文件不执行"),
                SessionModeOption(
                    id: "default", label: "默认 · 每步审批",
                    detail: "每条命令先问过你再执行"),
                SessionModeOption(
                    id: "auto", label: "自动 · 按需审批",
                    detail: "工作区内自动干活，越界操作才来问"),
                SessionModeOption(
                    id: "full", label: "完全放行",
                    detail: "不问审批、全盘可写——只给完全信任的仓库"),
            ]
        case .claude:
            return [
                SessionModeOption(
                    id: "plan", label: "计划 · 只读",
                    detail: "先出计划不动手，退出计划需确认"),
                SessionModeOption(
                    id: "default", label: "默认 · 每步审批",
                    detail: "每个工具调用先问过你再执行"),
                SessionModeOption(
                    id: "acceptEdits", label: "自动接受编辑",
                    detail: "文件编辑直接放行，命令仍要审批"),
                SessionModeOption(
                    id: "bypass", label: "完全放行",
                    detail: "跳过一切权限检查——只给完全信任的仓库"),
            ]
        case .cursor:
            return [
                SessionModeOption(
                    id: "agent", label: "Agent · 全能力",
                    detail: "读写与工具全开，需要审批的命令仍先问你"),
                SessionModeOption(
                    id: "plan", label: "计划 · 只读",
                    detail: "只读规划，先设计后动手"),
                SessionModeOption(
                    id: "ask", label: "问答 · 不动手",
                    detail: "只答问题，不编辑不执行"),
            ]
        }
    }

    static func defaultModeID(for agent: AgentKind) -> String {
        agent == .cursor ? "agent" : "default"
    }

    /// 放行一切的档位在选择器里标红——它们值得被多看一眼
    static func isDangerous(_ modeID: String) -> Bool {
        modeID == "full" || modeID == "bypass"
    }
}
