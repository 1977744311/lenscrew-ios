// Claude Code CLI 2.1.215 stdout/stdin 协议中 adapter 真正消费的子集。
//
// 驱动方式：
//   claude -p --input-format stream-json --output-format stream-json --verbose \
//          --include-partial-messages --permission-mode manual --replay-user-messages \
//          --permission-prompt-tool <name>
//
// 每个类型标注了验证状态，三档：
//   [实测]      2026-07-25 在本机 2.1.215 上跑出来的真实帧，已录入 protocol/fixtures/claude-turn.jsonl
//   [实测/mock] CLI 与协议帧是真的，只有模型响应来自本地 Anthropic 兼容 mock 端点
//               （本机 OAuth 过期，无法访问真模型；被替换的只有"模型说什么"，
//                 不是"CLI 怎么发帧"）
//   [依据文档]  来自 code.claude.com/docs/en/agent-sdk 或 CLI 内嵌字符串，未跑通
//
// 只声明用得上的字段。真实帧字段远多于此（stop_details / container / context_management /
// modelUsage / memory_paths 等），刻意不声明，避免把 CLI 的内部结构固化成契约。

// MARK: - Anthropic content block

/** [实测] assistant 消息里的思考块。--include-partial-messages 下 signature 由 signature_delta 补齐 */
export interface ClaudeThinkingBlock {
  type: "thinking";
  thinking: string;
}

/** [实测] */
export interface ClaudeTextBlock {
  type: "text";
  text: string;
}

/** [实测] input 在 assistant 整块帧里已是解析好的对象；stream_event 里则是 JSON 分片 */
export interface ClaudeToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

/**
 * [实测] 工具结果以 user 消息回灌。content 实测为 string；
 * 依据 Anthropic 消息规范也可能是 content block 数组，这里两种都收。
 */
export interface ClaudeToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content?: string | Array<{ type: string; text?: string }>;
  is_error?: boolean;
}

/** [依据文档] 思考内容被服务端脱敏时的替代块，本机未实测到 */
export interface ClaudeRedactedThinkingBlock {
  type: "redacted_thinking";
}

export type ClaudeContentBlock =
  | ClaudeThinkingBlock
  | ClaudeTextBlock
  | ClaudeToolUseBlock
  | ClaudeToolResultBlock
  | ClaudeRedactedThinkingBlock
  | { type: string };

// MARK: - 顶层 NDJSON 消息

/**
 * [实测] 每轮开始时发一次。
 *
 * 注意 permissionMode 不能反推 --permission-mode 传了什么：实测 manual 会被报成
 * "default"，其余取值（plan/auto/dontAsk/acceptEdits/bypassPermissions）原样回显。
 */
export interface ClaudeSystemInit {
  type: "system";
  subtype: "init";
  cwd: string;
  session_id: string;
  model: string;
  permissionMode: string;
  claude_code_version?: string;
  capabilities?: string[];
}

/** [实测] 401 时连发 10 次，attempt 递增。error_status 可能为 null（连接层失败） */
export interface ClaudeSystemApiRetry {
  type: "system";
  subtype: "api_retry";
  attempt: number;
  max_retries: number;
  error: string;
  error_status: number | null;
  session_id?: string;
}

/**
 * [实测] 其余 system 子类型：status / thinking_tokens / background_tasks_changed /
 * task_started / task_updated / task_notification。
 * [依据文档] permission_denied（CLI 内嵌字符串里存在，本机未触发到）。
 * 一律忽略——这些是 CLI 内部进度，折不进契约的 8 类 block。
 */
export interface ClaudeSystemOther {
  type: "system";
  subtype: string;
}

/**
 * [实测] 关键观测：CLI 每完成一个 content block 就发一条 assistant 帧，
 * 同一次模型响应的多条 assistant 帧共享同一个 message.id，各带一个块。
 * 所以 content 数组实测长度恒为 1，不能假设它承载整条消息。
 *
 * parent_tool_use_id 非空表示该消息来自 Task 子 agent（需 --forward-subagent-text）。
 * error 字段在鉴权失败等场景出现，实测值 "authentication_failed"。
 */
export interface ClaudeAssistantMessage {
  type: "assistant";
  message: {
    id?: string;
    model?: string;
    stop_reason?: string | null;
    content: ClaudeContentBlock[];
    usage?: ClaudeUsage;
  };
  parent_tool_use_id?: string | null;
  session_id?: string;
  error?: string;
}

/**
 * [实测] 两种来源：--replay-user-messages 回灌的用户输入（isReplay:true），
 * 以及工具结果回灌（isReplay 缺省，content 里是 tool_result 块）。
 * 必须靠 isReplay 区分，否则客户端会把自己刚发的消息当成新流水重复上屏。
 */
export interface ClaudeUserMessage {
  type: "user";
  message: {
    content: string | ClaudeContentBlock[];
  };
  parent_tool_use_id?: string | null;
  session_id?: string;
  isReplay?: boolean;
}

/** [实测] 顶层 usage 与 result.usage 同形 */
export interface ClaudeUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
}

/**
 * [实测] 陷阱：subtype 在实测到的三轮里恒为 "success"，鉴权失败那次也是 "success"，
 * 判错只能看 is_error。CLI 里另有 "error_max_turns"、"error_during_execution"
 * 两个 subtype[依据二进制内嵌字符串]，未实测，但它们同样会带 is_error。
 *
 * stop_reason / terminal_reason 是两套正交的收尾标记：
 * 前者是 Anthropic 模型侧的（end_turn / max_tokens / refusal / stop_sequence），
 * 后者是 CLI 会话侧的。[实测] 成功轮 end_turn + completed，
 * 鉴权失败轮 stop_sequence + api_error——注意失败时 stop_reason 仍是个正常值，
 * 所以不能只看 stop_reason 判成败。
 */
export interface ClaudeResult {
  type: "result";
  subtype: string;
  is_error: boolean;
  result?: string;
  session_id?: string;
  usage?: ClaudeUsage;
  stop_reason?: string | null;
  terminal_reason?: string;
}

/**
 * [实测] --include-partial-messages 产出的 token 级增量，
 * event 就是 Anthropic 原生 SSE 事件体。
 */
export interface ClaudeStreamEvent {
  type: "stream_event";
  event: ClaudeSseEvent;
  parent_tool_use_id?: string | null;
  session_id?: string;
}

export type ClaudeSseEvent =
  | {
      type: "content_block_start";
      index: number;
      content_block: ClaudeContentBlock;
    }
  | { type: "content_block_delta"; index: number; delta: ClaudeSseDelta }
  | { type: "content_block_stop"; index: number }
  | { type: string };

export type ClaudeSseDelta =
  | { type: "text_delta"; text: string }
  | { type: "thinking_delta"; thinking: string }
  | { type: "input_json_delta"; partial_json: string }
  | { type: string };

// MARK: - control protocol（CLI ↔ 客户端）

/**
 * [实测/mock] 审批请求。2026-07-25 在本机 2.1.215 上完整跑通了 allow 与 deny 两条路径。
 *
 * 要让 CLI 走这条通道而不是就地拒绝，三个条件缺一不可（实测逐个试出来的）：
 *   1. --input-format stream-json
 *   2. --permission-prompt-tool stdio：flag 在 2.1.215 的 --help 里已隐藏但仍有效，
 *      且 "stdio" 是保留字（见 adapter.ts 的 PERMISSION_PROMPT_TOOL 注释）。
 *      不带它 CLI 会把待审批工具直接判失败，回一条 is_error 的 tool_result
 *      （"Claude requested permissions to ..., but you haven't granted it yet."），
 *      stdout 上不会出现任何 control_request
 *   3. initialize 控制请求里注册 PreToolUse hook，用于把 stdin 流撑开到审批作答为止
 *
 * permission_suggestions 实测两种形状：Bash 给 addRules（可落成"总是允许"），
 * Write 给 setMode（切 acceptEdits）。
 */
export interface ClaudeCanUseToolRequest {
  subtype: "can_use_tool";
  tool_name: string;
  display_name?: string;
  input: Record<string, unknown>;
  tool_use_id?: string;
  description?: string;
  permission_suggestions?: unknown[];
  blocked_path?: string;
  decision_reason?: string;
  agent_id?: string;
}

/** [实测/mock] 注册了 PreToolUse hook 后每次工具调用前收到，必须作答否则该轮卡住 */
export interface ClaudeHookCallbackRequest {
  subtype: "hook_callback";
  callback_id: string;
  input?: Record<string, unknown>;
  tool_use_id?: string;
}

export type ClaudeControlRequestBody =
  | ClaudeCanUseToolRequest
  | ClaudeHookCallbackRequest
  | { subtype: string };

/** [实测] request_id 在顶层；应答里的 request_id 却在 response 内层，两边不对称 */
export interface ClaudeControlRequest {
  type: "control_request";
  request_id: string;
  request: ClaudeControlRequestBody;
}

/**
 * [实测] 客户端发 initialize / interrupt 后 CLI 的应答。
 * 成功：{subtype:"success", request_id, response}
 * 失败：{subtype:"error", request_id, error}（实测用未知 subtype 触发过）
 */
export interface ClaudeControlResponse {
  type: "control_response";
  response:
    | { subtype: "success"; request_id: string; response?: unknown }
    | { subtype: "error"; request_id: string; error: string };
}

export type ClaudeMessage =
  | ClaudeSystemInit
  | ClaudeSystemApiRetry
  | ClaudeSystemOther
  | ClaudeAssistantMessage
  | ClaudeUserMessage
  | ClaudeResult
  | ClaudeStreamEvent
  | ClaudeControlRequest
  | ClaudeControlResponse;

// MARK: - 写进 stdin 的消息

/** [实测] --input-format stream-json 接受的用户消息形状 */
export interface ClaudeStdinUserMessage {
  type: "user";
  message: { role: "user"; content: Array<{ type: "text"; text: string }> };
}

/**
 * [实测/mock] 审批裁决。CLI 内嵌的校验报错原文写明了它只认这两种：
 * "Expected {behavior: 'allow', updatedInput?: object} or {behavior: 'deny', message: string}."
 * deny 的 interrupt 字段来自 PermissionRequest hook 的 zod schema，[依据文档]，未实测。
 */
export type ClaudePermissionDecision =
  | { behavior: "allow"; updatedInput?: Record<string, unknown> }
  | { behavior: "deny"; message: string; interrupt?: boolean };

export interface ClaudeStdinControlRequest {
  type: "control_request";
  request_id: string;
  request: Record<string, unknown>;
}

export interface ClaudeStdinControlResponse {
  type: "control_response";
  response: { subtype: "success"; request_id: string; response: unknown };
}

export type ClaudeStdinMessage =
  | ClaudeStdinUserMessage
  | ClaudeStdinControlRequest
  | ClaudeStdinControlResponse;

// MARK: - 判别辅助

export function isControlRequest(m: ClaudeMessage): m is ClaudeControlRequest {
  return m.type === "control_request";
}

export function isCanUseTool(
  body: ClaudeControlRequestBody,
): body is ClaudeCanUseToolRequest {
  return body.subtype === "can_use_tool";
}

export function isHookCallback(
  body: ClaudeControlRequestBody,
): body is ClaudeHookCallbackRequest {
  return body.subtype === "hook_callback";
}
