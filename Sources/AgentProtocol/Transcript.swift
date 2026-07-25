import Foundation

public enum BlockStatus: String, Sendable, Codable {
    case pending, running, ok, failed, rejected
}

public struct FileChangeSummary: Sendable, Equatable, Codable {
    public var path: String
    public var added: Int
    public var removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct PlanStep: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case pending, running, done }
    public var text: String
    public var status: Status

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }
}

/// 会话流水的最小单元。三个运行时的原生条目（codex 的 18 类 ThreadItem、
/// claude 的 Anthropic content block、cursor 的 tool_call 变体）都在 bridge 侧
/// 折叠进这 8 类；折不进去的一律落进 toolCall 兜底，不新增类型。
///
/// 线上格式是扁平的 `{"kind": "...", "id": "...", ...}`，与 TS 侧的可辨识联合一致，
/// 所以 Codable 手写而不用编译器合成——合成版会把负载嵌进 `{"userMessage": {...}}`。
public enum TranscriptBlock: Sendable, Equatable {
    case userMessage(id: String, text: String, imageCount: Int)
    case agentMessage(id: String, text: String, streaming: Bool)
    case reasoning(id: String, text: String, streaming: Bool)
    case shellCommand(
        id: String, command: String, cwd: String?, output: String,
        exitCode: Int?, status: BlockStatus
    )
    case fileChange(id: String, files: [FileChangeSummary], status: BlockStatus)
    case toolCall(
        id: String, source: String?, tool: String, summary: String, status: BlockStatus
    )
    case plan(id: String, steps: [PlanStep])
    case error(id: String, message: String)

    public var id: String {
        switch self {
        case let .userMessage(id, _, _): return id
        case let .agentMessage(id, _, _): return id
        case let .reasoning(id, _, _): return id
        case let .shellCommand(id, _, _, _, _, _): return id
        case let .fileChange(id, _, _): return id
        case let .toolCall(id, _, _, _, _): return id
        case let .plan(id, _): return id
        case let .error(id, _): return id
        }
    }

    public var kind: String {
        switch self {
        case .userMessage: return "userMessage"
        case .agentMessage: return "agentMessage"
        case .reasoning: return "reasoning"
        case .shellCommand: return "shellCommand"
        case .fileChange: return "fileChange"
        case .toolCall: return "toolCall"
        case .plan: return "plan"
        case .error: return "error"
        }
    }
}

extension TranscriptBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, text, imageCount, streaming
        case command, cwd, output, exitCode, status
        case files, source, tool, summary, steps, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let id = try container.decode(String.self, forKey: .id)
        switch kind {
        case "userMessage":
            self = .userMessage(
                id: id,
                text: try container.decode(String.self, forKey: .text),
                imageCount: try container.decode(Int.self, forKey: .imageCount)
            )
        case "agentMessage":
            self = .agentMessage(
                id: id,
                text: try container.decode(String.self, forKey: .text),
                streaming: try container.decode(Bool.self, forKey: .streaming)
            )
        case "reasoning":
            self = .reasoning(
                id: id,
                text: try container.decode(String.self, forKey: .text),
                streaming: try container.decode(Bool.self, forKey: .streaming)
            )
        case "shellCommand":
            self = .shellCommand(
                id: id,
                command: try container.decode(String.self, forKey: .command),
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                output: try container.decode(String.self, forKey: .output),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
                status: try container.decode(BlockStatus.self, forKey: .status)
            )
        case "fileChange":
            self = .fileChange(
                id: id,
                files: try container.decode([FileChangeSummary].self, forKey: .files),
                status: try container.decode(BlockStatus.self, forKey: .status)
            )
        case "toolCall":
            self = .toolCall(
                id: id,
                source: try container.decodeIfPresent(String.self, forKey: .source),
                tool: try container.decode(String.self, forKey: .tool),
                summary: try container.decode(String.self, forKey: .summary),
                status: try container.decode(BlockStatus.self, forKey: .status)
            )
        case "plan":
            self = .plan(id: id, steps: try container.decode([PlanStep].self, forKey: .steps))
        case "error":
            self = .error(id: id, message: try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "未知的 TranscriptBlock kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        switch self {
        case let .userMessage(_, text, imageCount):
            try container.encode(text, forKey: .text)
            try container.encode(imageCount, forKey: .imageCount)
        case let .agentMessage(_, text, streaming), let .reasoning(_, text, streaming):
            try container.encode(text, forKey: .text)
            try container.encode(streaming, forKey: .streaming)
        case let .shellCommand(_, command, cwd, output, exitCode, status):
            try container.encode(command, forKey: .command)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(output, forKey: .output)
            try container.encode(exitCode, forKey: .exitCode)
            try container.encode(status, forKey: .status)
        case let .fileChange(_, files, status):
            try container.encode(files, forKey: .files)
            try container.encode(status, forKey: .status)
        case let .toolCall(_, source, tool, summary, status):
            try container.encode(source, forKey: .source)
            try container.encode(tool, forKey: .tool)
            try container.encode(summary, forKey: .summary)
            try container.encode(status, forKey: .status)
        case let .plan(_, steps):
            try container.encode(steps, forKey: .steps)
        case let .error(_, message):
            try container.encode(message, forKey: .message)
        }
    }
}

/// 增量更新。TS 侧是可选属性（`appendText?: string`），键要么缺席要么有值、
/// 不会是 null，因此这里全部用 encodeIfPresent。
public struct TranscriptBlockPatch: Sendable, Equatable, Codable {
    public var appendText: String?
    public var replaceText: String?
    public var streaming: Bool?
    public var status: BlockStatus?
    public var exitCode: Int?
    public var files: [FileChangeSummary]?
    public var steps: [PlanStep]?

    public init(
        appendText: String? = nil, replaceText: String? = nil, streaming: Bool? = nil,
        status: BlockStatus? = nil, exitCode: Int? = nil,
        files: [FileChangeSummary]? = nil, steps: [PlanStep]? = nil
    ) {
        self.appendText = appendText
        self.replaceText = replaceText
        self.streaming = streaming
        self.status = status
        self.exitCode = exitCode
        self.files = files
        self.steps = steps
    }
}

extension TranscriptBlock {
    /// 就地应用增量。kind 与补丁字段不匹配时忽略该字段而不是抛错——
    /// bridge 可能比 App 新，多出来的字段不应该让整条流水崩掉。
    public func applying(_ patch: TranscriptBlockPatch) -> TranscriptBlock {
        func mergedText(_ current: String) -> String {
            if let replaceText = patch.replaceText { return replaceText }
            if let appendText = patch.appendText { return current + appendText }
            return current
        }

        switch self {
        case let .userMessage(id, text, imageCount):
            return .userMessage(id: id, text: mergedText(text), imageCount: imageCount)
        case let .agentMessage(id, text, streaming):
            return .agentMessage(
                id: id, text: mergedText(text), streaming: patch.streaming ?? streaming
            )
        case let .reasoning(id, text, streaming):
            return .reasoning(
                id: id, text: mergedText(text), streaming: patch.streaming ?? streaming
            )
        case let .shellCommand(id, command, cwd, output, exitCode, status):
            return .shellCommand(
                id: id, command: command, cwd: cwd, output: mergedText(output),
                exitCode: patch.exitCode ?? exitCode, status: patch.status ?? status
            )
        case let .fileChange(id, files, status):
            return .fileChange(
                id: id, files: patch.files ?? files, status: patch.status ?? status
            )
        case let .toolCall(id, source, tool, summary, status):
            return .toolCall(
                id: id, source: source, tool: tool,
                summary: patch.replaceText ?? summary, status: patch.status ?? status
            )
        case let .plan(id, steps):
            return .plan(id: id, steps: patch.steps ?? steps)
        case let .error(id, message):
            return .error(id: id, message: mergedText(message))
        }
    }
}
