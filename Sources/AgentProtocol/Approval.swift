import Foundation

public enum ApprovalKind: String, Sendable, Codable {
    case shellCommand, fileChange, tool, permission
}

public enum ApprovalOptionKind: String, Sendable, Codable {
    case allow, allowAlways, deny, abort
}

public struct ApprovalOption: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var label: String
    public var kind: ApprovalOptionKind

    public init(id: String, label: String, kind: ApprovalOptionKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

/// 审批请求。`title` 是唯一保证能在 600×600 眼镜屏一行放下的字段；
/// `detail` 可能是整段命令或 diff，眼镜端必须分页，手机端可整段展示。
public struct ApprovalRequest: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var kind: ApprovalKind
    public var title: String
    public var detail: String
    public var cwd: String?
    public var options: [ApprovalOption]
    public var requestedAtMs: Int64

    public init(
        id: String, kind: ApprovalKind, title: String, detail: String,
        cwd: String?, options: [ApprovalOption], requestedAtMs: Int64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.cwd = cwd
        self.options = options
        self.requestedAtMs = requestedAtMs
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(options, forKey: .options)
        try container.encode(requestedAtMs, forKey: .requestedAtMs)
    }
}

public enum ApprovalOutcome: String, Sendable, Codable {
    case resolved, cancelled, timedOut
}
