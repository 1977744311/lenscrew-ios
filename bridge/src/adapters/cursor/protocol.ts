// Cursor Agent ACP（cursor-agent acp）协议子集。
//
// 来源标注：
//   [实测] = 2026-07-25 在 cursor-agent 2026.07.23-e383d2b 上抓到的真实报文
//            （protocol/fixtures/cursor-acp-turn.jsonl）
//   [规范] = agentclientprotocol.com 的 ACP schema 里有、但本轮没抓到实例
// 两者冲突时以实测为准，冲突点就地注明。
//
// 这里只声明我们真正读的字段。原生报文远比这里宽（例如 shell 工具调用会带完整的
// bash 解析树），多出来的字段一律不进类型——写进来就等于承诺会跟着它变。
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
