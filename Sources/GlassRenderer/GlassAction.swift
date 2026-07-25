import Foundation

/// 眼镜端能发出的全部动作。
///
/// DAT 只有 tap：没有文本输入、没有滑动回调、没有长按。所以整个眼镜端交互
/// 必须能被这几个离散动作表达完，翻页也只能靠显式按钮而不是滚动。
public enum GlassAction: Sendable, Equatable {
    case openSession(String)
    case openBlock(String)
    case pageNext
    case pagePrevious
    /// 跳到最新一页并恢复跟随
    case jumpToLatest
    case back
    case resolveApproval(optionID: String)
}

extension GlassAction {
    /// 组件 onTap 只能携带一个字符串，动作在这里编解码。
    /// 用首个冒号切分，因此负载里再出现冒号也安全（会话 id、审批选项 id 都可能带）。
    public var actionID: String {
        switch self {
        case let .openSession(id): return "session:\(id)"
        case let .openBlock(id): return "block:\(id)"
        case .pageNext: return "page:next"
        case .pagePrevious: return "page:prev"
        case .jumpToLatest: return "page:latest"
        case .back: return "nav:back"
        case let .resolveApproval(optionID): return "approve:\(optionID)"
        }
    }

    public init?(actionID: String) {
        guard let separator = actionID.firstIndex(of: ":") else { return nil }
        let prefix = String(actionID[actionID.startIndex..<separator])
        let payload = String(actionID[actionID.index(after: separator)...])
        switch (prefix, payload) {
        case ("session", let id) where !id.isEmpty:
            self = .openSession(id)
        case ("block", let id) where !id.isEmpty:
            self = .openBlock(id)
        case ("page", "next"):
            self = .pageNext
        case ("page", "prev"):
            self = .pagePrevious
        case ("page", "latest"):
            self = .jumpToLatest
        case ("nav", "back"):
            self = .back
        case ("approve", let optionID) where !optionID.isEmpty:
            self = .resolveApproval(optionID: optionID)
        default:
            return nil
        }
    }
}
