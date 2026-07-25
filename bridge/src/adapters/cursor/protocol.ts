// Cursor Agent 两条驱动路径各自消费的协议子集。
//
// 来源标注：
//   [实测] = 2026-07-25 在 cursor-agent 2026.07.23-e383d2b 上抓到的真实报文
//            （protocol/fixtures/cursor-print-turn.jsonl、cursor-acp-turn.jsonl）
//   [规范] = agentclientprotocol.com 的 ACP schema 里有、但本轮没抓到实例
// 两者冲突时以实测为准，冲突点就地注明。
//
// 这里只声明我们真正读的字段。原生报文远比这里宽（例如 shell 工具调用会带完整的
// bash 解析树），多出来的字段一律不进类型——写进来就等于承诺会跟着它变。

// MARK: - 路径 A：cursor-agent -p --output-format stream-json
//
// 一行一条 JSON，按 type 分派。整条链路没有审批通道：需要审批的 shell 调用不会问
// 客户端，而是直接以 tool_call/completed + result.rejected 收场（见 CursorShellRejected）。

export interface CursorPrintContentBlock {
  /** [实测] 只见过 "text"；"image" 依 -p 支持图片输入推得 */
  type: string;
  text?: string;
}

/** [实测] type:"system"。subtype 目前只见过 "init" */
export interface CursorPrintSystem {
  type: "system";
  subtype: string;
  cwd?: string;
  session_id?: string;
  model?: string;
  /** [实测] "default"；--force / --auto-review 下的取值未测 */
  permissionMode?: string;
  apiKeySource?: string;
}

export interface CursorPrintUser {
  type: "user";
  message: { role: "user"; content: CursorPrintContentBlock[] };
  session_id: string;
}

/**
 * [实测] 不带 --stream-partial-output 时，每条 assistant 就是一段完整文本。
 *
 * 坑：加上 --stream-partial-output 后，同一段文本会先以多条带 timestamp_ms 的
 * 增量发出，末尾再整段重发一次（不带 timestamp_ms 和 model_call_id）。天真地按条
 * 追加会让整段回复出现两遍，所以 adapter 不开这个 flag。
 */
export interface CursorPrintAssistant {
  type: "assistant";
  message: { role: "assistant"; content: CursorPrintContentBlock[] };
  session_id: string;
  model_call_id?: string;
  timestamp_ms?: number;
}

/** [实测] 思考链默认就是增量；completed 那条不带 text */
export interface CursorPrintThinking {
  type: "thinking";
  subtype: "delta" | "completed";
  text?: string;
  session_id: string;
  timestamp_ms?: number;
}

export interface CursorShellArgs {
  command?: string;
  /** [实测] started 时恒为空串，真实路径只在 result 里给 */
  workingDirectory?: string;
  description?: string;
}

/** [实测] --force 放行后的成功结果 */
export interface CursorShellSuccess {
  command?: string;
  workingDirectory?: string;
  exitCode?: number;
  signal?: string;
  stdout?: string;
  stderr?: string;
  /** [实测] stdout/stderr 按时序合流，比分别拼接更贴近终端里看到的样子 */
  interleavedOutput?: string;
}

/**
 * [实测] -p 模式下需要审批的命令直接落到这里。reason 抓到时是空串，
 * 也就是说客户端连「为什么被拒」都拿不到，更没有改判的机会。
 */
export interface CursorShellRejected {
  command?: string;
  workingDirectory?: string;
  reason?: string;
  isReadonly?: boolean;
}

export interface CursorShellResult {
  success?: CursorShellSuccess;
  rejected?: CursorShellRejected;
}

export interface CursorShellToolCall {
  args?: CursorShellArgs;
  result?: CursorShellResult;
  description?: string;
}

/**
 * [实测] shell 之外的变体（读写文件、MCP 等）本轮没抓到，按 shellToolCall 的命名规律
 * 推断为同层的 xxxToolCall 键，因此保留索引签名让 normalizer 能兜底成通用 toolCall。
 */
export interface CursorPrintToolCallPayload {
  toolCallId: string;
  shellToolCall?: CursorShellToolCall;
  startedAtMs?: string;
  completedAtMs?: string;
  [key: string]: unknown;
}

export interface CursorPrintToolCall {
  type: "tool_call";
  subtype: "started" | "completed";
  call_id: string;
  tool_call: CursorPrintToolCallPayload;
  session_id: string;
  model_call_id?: string;
  timestamp_ms?: number;
}

/** [实测] 只有这里给 token 用量；ACP 路径没有对应物 */
export interface CursorPrintUsage {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
}

export interface CursorPrintResult {
  type: "result";
  /** [实测] "success"；失败时的取值未测，故不收窄成字面量 */
  subtype: string;
  duration_ms?: number;
  is_error: boolean;
  result: string;
  session_id: string;
  request_id?: string;
  usage?: CursorPrintUsage;
}

export type CursorPrintMessage =
  | CursorPrintSystem
  | CursorPrintUser
  | CursorPrintAssistant
  | CursorPrintThinking
  | CursorPrintToolCall
  | CursorPrintResult;

// MARK: - 路径 B：cursor-agent acp
//
// stdio 上的换行分隔 JSON-RPC 2.0（不是 LSP 的 Content-Length 分帧）。

export type JsonRpcId = number | string;

export interface JsonRpcErrorBody {
  code: number;
  message: string;
  data?: unknown;
}

/**
 * 一行 JSON-RPC 报文。请求/通知/响应共用一个可选字段的形状，而不是三个接口的联合：
 * 逐行读进来时本来就得靠字段在不在来判型，联合类型只会把这件事挪到收窄语法里。
 *
 * 方向不在报文里。判定规则见 acpNormalizer.ts —— method 归属固定的一侧，
 * 响应则靠 id 命名空间区分（我们发出的请求 id 一律是 "lc-<n>" 字符串，
 * [实测] agent 自己发的请求 id 是从 0 开始的数字，两边不会撞）。
 */
export interface AcpWireMessage {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: JsonRpcErrorBody;
}

export interface AcpContentBlock {
  /** [规范] text | image | audio | resource | resource_link */
  type: string;
  text?: string;
}

/** [规范] 完整取值见 ACP ToolKind；[实测] 只见过 "execute" */
export type AcpToolKind =
  | "read"
  | "edit"
  | "delete"
  | "move"
  | "search"
  | "execute"
  | "think"
  | "fetch"
  | "switch_mode"
  | "other";

export type AcpToolCallStatus = "pending" | "in_progress" | "completed" | "failed";

/** [实测] request_permission 里出现的是 {type:"content", content:{type:"text"}} 这一种 */
export interface AcpToolCallContentItem {
  type: string;
  content?: AcpContentBlock;
  path?: string;
  oldText?: string | null;
  newText?: string;
}

export interface AcpToolCallInfo {
  /**
   * [实测] 内容不保证是「干净」的标识符：GPT 系模型下抓到的 id 是
   * "call_xxx\nfc_yyy"（中间真的有换行）。只当作不透明的相关键使用。
   */
  toolCallId: string;
  title?: string;
  kind?: AcpToolKind;
  status?: AcpToolCallStatus;
  content?: AcpToolCallContentItem[];
  /** [实测] shell 调用是 {command}；没有工作目录字段 */
  rawInput?: { command?: string };
  /** [实测] shell 完成时是 {exitCode, stdout, stderr} */
  rawOutput?: { exitCode?: number; stdout?: string; stderr?: string };
}

export interface AcpPlanEntry {
  content: string;
  priority: "high" | "medium" | "low";
  status: "pending" | "in_progress" | "completed";
}

/**
 * session/update 通知的载荷。[实测] 跑通过 session_info_update、
 * available_commands_update、agent_message_chunk、agent_thought_chunk、
 * tool_call、tool_call_update；其余按 [规范] 声明。
 * normalizer 对未知 sessionUpdate 一律忽略。
 */
export type AcpSessionUpdate =
  | { sessionUpdate: "agent_message_chunk"; content: AcpContentBlock }
  | { sessionUpdate: "agent_thought_chunk"; content: AcpContentBlock }
  | { sessionUpdate: "user_message_chunk"; content: AcpContentBlock }
  | ({ sessionUpdate: "tool_call" } & AcpToolCallInfo)
  | ({ sessionUpdate: "tool_call_update" } & AcpToolCallInfo)
  | { sessionUpdate: "plan"; entries: AcpPlanEntry[] }
  | { sessionUpdate: "session_info_update"; title?: string | null }
  | { sessionUpdate: "available_commands_update"; availableCommands: unknown[] }
  | { sessionUpdate: "current_mode_update"; currentModeId: string }
  | { sessionUpdate: "usage_update"; used: number; size: number };

export interface AcpSessionNotificationParams {
  sessionId: string;
  update: AcpSessionUpdate;
}

/** [实测] cursor 给的三个选项：allow-once / allow-always / reject-once */
export type AcpPermissionOptionKind =
  | "allow_once"
  | "allow_always"
  | "reject_once"
  | "reject_always";

/** [实测] 字段名是 name，不是 label */
export interface AcpPermissionOption {
  optionId: string;
  name: string;
  kind: AcpPermissionOptionKind;
}

export interface AcpRequestPermissionParams {
  sessionId: string;
  toolCall: AcpToolCallInfo;
  options: AcpPermissionOption[];
}

export type AcpRequestPermissionOutcome =
  | { outcome: "selected"; optionId: string }
  | { outcome: "cancelled" };

export interface AcpRequestPermissionResult {
  outcome: AcpRequestPermissionOutcome;
}

export interface AcpPromptParams {
  sessionId: string;
  prompt: AcpContentBlock[];
}

/** [实测] 只有 stopReason，没有任何 token 用量 */
export type AcpStopReason =
  | "end_turn"
  | "max_tokens"
  | "max_turn_requests"
  | "refusal"
  | "cancelled";

export interface AcpPromptResult {
  stopReason: AcpStopReason;
}

export interface AcpAgentCapabilities {
  /** [实测] cursor 报 true，且新进程里 session/load 一个历史会话确实能拉起来 */
  loadSession?: boolean;
  promptCapabilities?: { image?: boolean; audio?: boolean; embeddedContext?: boolean };
}

export interface AcpInitializeResult {
  protocolVersion: number;
  agentCapabilities?: AcpAgentCapabilities;
  authMethods?: Array<{ id: string; name?: string; description?: string }>;
}

export interface AcpSessionModeState {
  currentModeId: string;
  availableModes: Array<{ id: string; name?: string; description?: string }>;
}

export interface AcpSessionModelState {
  currentModelId: string;
  availableModels: Array<{ modelId: string; name?: string }>;
}

/** session/new 与 session/load 的响应形状一致（[实测] load 不带 sessionId） */
export interface AcpNewSessionResult {
  sessionId?: string;
  modes?: AcpSessionModeState;
  models?: AcpSessionModelState;
}
