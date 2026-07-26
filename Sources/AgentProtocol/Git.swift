// bridge/src/protocol/git.ts 的 Swift 同构镜像 —— git 操作面板的线上契约。
// 与会话事件分开：git 是请求-应答语义，结果只回发起请求的手机，
// 不进事件流、没有 seq。两侧共用 protocol/fixtures/git-panel.json 做往返测试。
import Foundation

/// 手机端发起的 git 请求。root 一律是 Mac 上的绝对路径（通常取会话的 workspaceRoot）。
public enum GitRequest: Sendable, Equatable {
    case status(root: String)
    /// path 为 nil 看整仓 diff；staged 区分暂存区与工作区
    case diff(root: String, path: String?, staged: Bool)
    case log(root: String, limit: Int)
    case branches(root: String)
    /// paths 为空数组表示全部
    case stage(root: String, paths: [String])
    case unstage(root: String, paths: [String])
    /// 破坏性操作，paths 必须显式非空
    case discard(root: String, paths: [String])
    case commit(root: String, message: String)
    case push(root: String)
    case pull(root: String)
    case checkout(root: String, branch: String, create: Bool)
    case stash(root: String)
    case stashPop(root: String)
}

/// porcelain 状态字母：M/A/D/R/C/T/U，untracked 恒为 "?"
public struct GitFileChange: Sendable, Equatable, Codable, Identifiable {
    public var path: String
    public var code: String
    /// rename/copy 的旧路径；其余为 nil
    public var oldPath: String?

    public var id: String { "\(code):\(path)" }

    public init(path: String, code: String, oldPath: String?) {
        self.path = path
        self.code = code
        self.oldPath = oldPath
    }

    // TS 侧是 `string | null` 而非可选属性，键必须始终存在
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(code, forKey: .code)
        try container.encode(oldPath, forKey: .oldPath)
    }
}

public struct GitStatusSummary: Sendable, Equatable, Codable {
    /// 当前分支名；detached HEAD 时为 nil
    public var branch: String?
    /// upstream 短名（origin/main）；未设 upstream 为 nil
    public var upstream: String?
    /// 相对 upstream 的领先/落后；无 upstream 时为 nil——填 0 是在撒谎
    public var ahead: Int?
    public var behind: Int?
    public var staged: [GitFileChange]
    /// 工作区改动，含 untracked（code "?"）与冲突（code "U"）
    public var unstaged: [GitFileChange]
    public var stashCount: Int

    public init(
        branch: String?, upstream: String?, ahead: Int?, behind: Int?,
        staged: [GitFileChange], unstaged: [GitFileChange], stashCount: Int
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.stashCount = stashCount
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branch, forKey: .branch)
        try container.encode(upstream, forKey: .upstream)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
        try container.encode(staged, forKey: .staged)
        try container.encode(unstaged, forKey: .unstaged)
        try container.encode(stashCount, forKey: .stashCount)
    }
}

public struct GitLogEntry: Sendable, Equatable, Codable, Identifiable {
    public var sha: String
    public var subject: String
    public var author: String
    public var timeMs: Int64

    public var id: String { sha }

    public init(sha: String, subject: String, author: String, timeMs: Int64) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.timeMs = timeMs
    }
}

/// git 请求的应答。查询各有专属载荷；写操作统一 done + 人读输出。
/// 失败不在这里表达——传输层以 `{ ok: false, error }` 回，error 就是给用户看的内容。
public enum GitOutcome: Sendable, Equatable {
    case status(GitStatusSummary)
    /// 超过上限的 diff 会被截断，truncated 告知"还有更多"
    case diff(text: String, truncated: Bool)
    case log(entries: [GitLogEntry])
    case branches(current: String?, local: [String])
    case done(detail: String)
}

extension GitRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, root, path, staged, limit, paths, message, branch, create
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        let root = try container.decode(String.self, forKey: .root)
        switch op {
        case "status":
            self = .status(root: root)
        case "diff":
            self = .diff(
                root: root,
                path: try container.decodeIfPresent(String.self, forKey: .path),
                staged: try container.decode(Bool.self, forKey: .staged)
            )
        case "log":
            self = .log(root: root, limit: try container.decode(Int.self, forKey: .limit))
        case "branches":
            self = .branches(root: root)
        case "stage":
            self = .stage(root: root, paths: try container.decode([String].self, forKey: .paths))
        case "unstage":
            self = .unstage(root: root, paths: try container.decode([String].self, forKey: .paths))
        case "discard":
            self = .discard(root: root, paths: try container.decode([String].self, forKey: .paths))
        case "commit":
            self = .commit(
                root: root, message: try container.decode(String.self, forKey: .message)
            )
        case "push":
            self = .push(root: root)
        case "pull":
            self = .pull(root: root)
        case "checkout":
            self = .checkout(
                root: root,
                branch: try container.decode(String.self, forKey: .branch),
                create: try container.decode(Bool.self, forKey: .create)
            )
        case "stash":
            self = .stash(root: root)
        case "stashPop":
            self = .stashPop(root: root)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container,
                debugDescription: "未知的 GitRequest op: \(op)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .status(root):
            try container.encode("status", forKey: .op)
            try container.encode(root, forKey: .root)
        case let .diff(root, path, staged):
            try container.encode("diff", forKey: .op)
            try container.encode(root, forKey: .root)
            // TS 侧是 `string | null`，键必须始终存在
            try container.encode(path, forKey: .path)
            try container.encode(staged, forKey: .staged)
        case let .log(root, limit):
            try container.encode("log", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(limit, forKey: .limit)
        case let .branches(root):
            try container.encode("branches", forKey: .op)
            try container.encode(root, forKey: .root)
        case let .stage(root, paths):
            try container.encode("stage", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(paths, forKey: .paths)
        case let .unstage(root, paths):
            try container.encode("unstage", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(paths, forKey: .paths)
        case let .discard(root, paths):
            try container.encode("discard", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(paths, forKey: .paths)
        case let .commit(root, message):
            try container.encode("commit", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(message, forKey: .message)
        case let .push(root):
            try container.encode("push", forKey: .op)
            try container.encode(root, forKey: .root)
        case let .pull(root):
            try container.encode("pull", forKey: .op)
            try container.encode(root, forKey: .root)
        case let .checkout(root, branch, create):
            try container.encode("checkout", forKey: .op)
            try container.encode(root, forKey: .root)
            try container.encode(branch, forKey: .branch)
            try container.encode(create, forKey: .create)
        case let .stash(root):
            try container.encode("stash", forKey: .op)
            try container.encode(root, forKey: .root)
        case let .stashPop(root):
            try container.encode("stashPop", forKey: .op)
            try container.encode(root, forKey: .root)
        }
    }
}

extension GitOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, status, text, truncated, entries, current, local, detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "status":
            self = .status(try container.decode(GitStatusSummary.self, forKey: .status))
        case "diff":
            self = .diff(
                text: try container.decode(String.self, forKey: .text),
                truncated: try container.decode(Bool.self, forKey: .truncated)
            )
        case "log":
            self = .log(entries: try container.decode([GitLogEntry].self, forKey: .entries))
        case "branches":
            self = .branches(
                current: try container.decodeIfPresent(String.self, forKey: .current),
                local: try container.decode([String].self, forKey: .local)
            )
        case "done":
            self = .done(detail: try container.decode(String.self, forKey: .detail))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "未知的 GitOutcome kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .status(status):
            try container.encode("status", forKey: .kind)
            try container.encode(status, forKey: .status)
        case let .diff(text, truncated):
            try container.encode("diff", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(truncated, forKey: .truncated)
        case let .log(entries):
            try container.encode("log", forKey: .kind)
            try container.encode(entries, forKey: .entries)
        case let .branches(current, local):
            try container.encode("branches", forKey: .kind)
            // TS 侧是 `string | null`，键必须始终存在
            try container.encode(current, forKey: .current)
            try container.encode(local, forKey: .local)
        case let .done(detail):
            try container.encode("done", forKey: .kind)
            try container.encode(detail, forKey: .detail)
        }
    }
}
