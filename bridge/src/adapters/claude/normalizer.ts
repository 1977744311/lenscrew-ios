import type {
  ApprovalOption,
  BlockStatus,
  TranscriptBlock,
  TranscriptBlockPatch,
  TurnStopReason,
} from "../../protocol/events.ts";
import type { AdapterEvent, ProtocolNormalizer } from "../types.ts";
import type {
  ClaudeAssistantMessage,
  ClaudeCanUseToolRequest,
  ClaudeContentBlock,
  ClaudeControlRequest,
  ClaudeMessage,
  ClaudeResult,
  ClaudeStreamEvent,
  ClaudeSystemApiRetry,
  ClaudeSystemInit,
  ClaudeToolResultBlock,
  ClaudeToolUseBlock,
  ClaudeUserMessage,
} from "./protocol.ts";

/** 折叠成契约 block 之后仍需回填的种类 */
type TrackedKind = "agentMessage" | "reasoning" | "shellCommand" | "fileChange" | "toolCall";

interface TrackedBlock {
  blockId: string;
  kind: TrackedKind;
  toolUseId: string | null;
  /** stream_event 的 content block 下标；未开启 --include-partial-messages 时为 null */
  streamIndex: number | null;
  /** 已被 assistant 整块帧或 content_block_stop 收口 */
  closed: boolean;
}

export interface ClaudeNormalizerOptions {
  /** 注入时钟只为让 normalize 在测试里确定可复现；生产用 Date.now */
  now?: () => number;
  /** block id 前缀，多会话共存时避免撞号 */
  idPrefix?: string;
}

/** 眼镜端一行能放下的长度上限，超出由客户端省略 */
const TITLE_MAX = 48;
const SUMMARY_MAX = 80;

const FILE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);

export class ClaudeNormalizer implements ProtocolNormalizer<ClaudeMessage> {
  private readonly now: () => number;
  private readonly idPrefix: string;

  private seq = 0;
  private cwd: string | null = null;
  /** 按出现顺序保存未收口的块，用于把 assistant 整块帧对上此前 stream 开的块 */
  private open: TrackedBlock[] = [];
  private byStreamIndex = new Map<number, TrackedBlock>();
  private byToolUseId = new Map<string, TrackedBlock>();
  /** 子 agent 文本按父 tool_use_id 累积，折进父块的 summary */
  private subagentText = new Map<string, string>();
  /** 鉴权失败会在 assistant 和 result 上各报一次同样的话，去重后只报一次 */
  private lastFatalMessage: string | null = null;

  constructor(options: ClaudeNormalizerOptions = {}) {
    this.now = options.now ?? Date.now;
    this.idPrefix = options.idPrefix ?? "claude";
  }

  normalize(message: ClaudeMessage): AdapterEvent[] {
    switch (message.type) {
      case "system":
        return this.onSystem(message as ClaudeSystemInit | ClaudeSystemApiRetry);
      case "assistant":
        return this.onAssistant(message as ClaudeAssistantMessage);
      case "user":
        return this.onUser(message as ClaudeUserMessage);
      case "stream_event":
        return this.onStreamEvent(message as ClaudeStreamEvent);
      case "control_request":
        return this.onControlRequest(message as ClaudeControlRequest);
      case "result":
        return this.onResult(message as ClaudeResult);
      default:
        return [];
    }
  }

  // MARK: - system

  private onSystem(message: ClaudeSystemInit | ClaudeSystemApiRetry): AdapterEvent[] {
    if (message.subtype === "init") {
      const init = message as ClaudeSystemInit;
      this.cwd = init.cwd ?? null;
      const events: AdapterEvent[] = [];
      if (init.session_id) {
        events.push({ type: "nativeIdAssigned", nativeId: init.session_id });
      }
      if (init.model) {
        events.push({ type: "modelResolved", model: init.model });
      }
      // 不发 titleResolved：init 及后续所有帧都不带会话标题，CLI 的标题生成
      // 是另一条要主动发起的控制请求（会额外烧一次模型调用），拿不到就按契约不发
      events.push({ type: "status", status: "running" });
      return events;
    }

    if (message.subtype === "api_retry") {
      const retry = message as ClaudeSystemApiRetry;
      const status = retry.error_status === null ? "" : ` ${retry.error_status}`;
      // 非致命：CLI 自己还会重试，客户端只要看见在退避就行
      return [
        {
          type: "error",
          message: `Claude API 重试 ${retry.attempt}/${retry.max_retries}${status}: ${retry.error}`,
          fatal: false,
        },
      ];
    }

    // status / thinking_tokens / task_* / background_tasks_changed 等纯进度信号，不入流水
    return [];
  }

  // MARK: - assistant

  private onAssistant(message: ClaudeAssistantMessage): AdapterEvent[] {
    const events: AdapterEvent[] = [];

    if (message.error) {
      const text = firstText(message.message?.content ?? []);
      const detail = text.length > 0 ? text : message.error;
      this.lastFatalMessage = detail;
      return [
        { type: "error", message: detail, fatal: true },
        { type: "status", status: "error" },
      ];
    }

    const parent = message.parent_tool_use_id;
    if (parent) {
      return this.foldSubagent(parent, message.message?.content ?? []);
    }

    for (const block of message.message?.content ?? []) {
      events.push(...this.onCompletedBlock(block));
    }
    return events;
  }

  /**
   * 子 agent（Task 工具）的消息不独立成块，而是压缩进父 toolCall 的 summary。
   *
   * 理由：眼镜屏 600×600，一次 Task 里子 agent 可能产出几十条消息，独立成块会把
   * 主线冲没。契约里 toolCall.summary 定位就是一行摘要，所以这里累积后截断重写。
   * 走 summary 字段而不是 appendText——后者对 toolCall 打的是 output，
   * 那里留给 Task 自己的 tool_result 正文。子 agent 的 thinking 和它自己的工具调用
   * 直接丢弃，手机端要看细节应当去看父 Task 的 output。
   */
  private foldSubagent(parentToolUseId: string, blocks: ClaudeContentBlock[]): AdapterEvent[] {
    const parent = this.byToolUseId.get(parentToolUseId);
    if (!parent) return [];

    let added = "";
    for (const block of blocks) {
      if (block.type === "text") {
        added += (block as { text?: string }).text ?? "";
      }
    }
    if (added.length === 0) return [];

    const merged = (this.subagentText.get(parentToolUseId) ?? "") + added;
    this.subagentText.set(parentToolUseId, merged);
    return [
      {
        type: "blockUpdated",
        blockId: parent.blockId,
        patch: { summary: condense(merged, SUMMARY_MAX) },
      },
    ];
  }

  /**
   * 一条 assistant 帧只带一个已完成的块（实测）。若此前 stream_event 已经为它开过块，
   * 就用权威内容收口；否则（没开 --include-partial-messages）直接追加新块。
   */
  private onCompletedBlock(block: ClaudeContentBlock): AdapterEvent[] {
    switch (block.type) {
      case "text": {
        const text = (block as { text?: string }).text ?? "";
        return this.closeOrAppend("agentMessage", null, text, () => ({
          kind: "agentMessage",
          id: this.nextId(),
          text,
          streaming: false,
        }));
      }
      case "thinking": {
        const text = (block as { thinking?: string }).thinking ?? "";
        return this.closeOrAppend("reasoning", null, text, () => ({
          kind: "reasoning",
          id: this.nextId(),
          text,
          streaming: false,
        }));
      }
      case "tool_use":
        return this.onToolUse(block as ClaudeToolUseBlock);
      default:
        return [];
    }
  }

  private closeOrAppend(
    kind: TrackedKind,
    toolUseId: string | null,
    finalText: string,
    make: () => TranscriptBlock,
  ): AdapterEvent[] {
    const tracked = this.takeOpen(kind, toolUseId);
    if (tracked) {
      tracked.closed = true;
      return [
        {
          type: "blockUpdated",
          blockId: tracked.blockId,
          patch: { replaceText: finalText, streaming: false },
        },
      ];
    }
    const block = make();
    this.track(block.id, kind, toolUseId, null, true);
    return [{ type: "blockAppended", block }];
  }

  private onToolUse(block: ClaudeToolUseBlock): AdapterEvent[] {
    const existing = block.id ? this.byToolUseId.get(block.id) : undefined;
    const kind = classifyTool(block.name);

    if (existing) {
      existing.closed = true;
      // stream 开块时 input 还是空的，这里才拿得到解析好的参数
      const patch = describeToolInput(kind, block, this.cwd);
      return patch ? [{ type: "blockUpdated", blockId: existing.blockId, patch }] : [];
    }

    const transcript = buildToolBlock(this.nextId(), kind, block, this.cwd);
    this.track(transcript.id, kind, block.id ?? null, null, true);
    return [{ type: "blockAppended", block: transcript }];
  }

  // MARK: - user（回放 + 工具结果）

  private onUser(message: ClaudeUserMessage): AdapterEvent[] {
    const content = message.message?.content;

    // --replay-user-messages 的回声：CLI 确认收到了这条输入
    if (message.isReplay === true) {
      const text = typeof content === "string" ? content : firstText(content ?? []);
      return [
        {
          type: "blockAppended",
          block: { kind: "userMessage", id: this.nextId(), text, imageCount: 0 },
        },
      ];
    }

    if (typeof content === "string" || !content) return [];

    const events: AdapterEvent[] = [];
    for (const block of content) {
      if (block.type !== "tool_result") continue;
      events.push(...this.onToolResult(block as ClaudeToolResultBlock));
    }
    return events;
  }

  private onToolResult(block: ClaudeToolResultBlock): AdapterEvent[] {
    const tracked = block.tool_use_id ? this.byToolUseId.get(block.tool_use_id) : undefined;
    if (!tracked) return [];

    const status: BlockStatus = block.is_error === true ? "failed" : "ok";
    const output = toolResultText(block);

    // shellCommand 和 toolCall 的主文本都是 output；fileChange 没有主文本位，只落 status
    const patch: TranscriptBlockPatch =
      tracked.kind === "fileChange" || output.length === 0
        ? { status }
        : { appendText: output, status };

    return [{ type: "blockUpdated", blockId: tracked.blockId, patch }];
  }

  // MARK: - stream_event

  private onStreamEvent(message: ClaudeStreamEvent): AdapterEvent[] {
    // 子 agent 的增量不单独上屏，父块的摘要由 foldSubagent 负责
    if (message.parent_tool_use_id) return [];

    const event = message.event;
    if (!event || typeof event.type !== "string") return [];

    if (event.type === "content_block_start") {
      const start = event as { index: number; content_block: ClaudeContentBlock };
      return this.onBlockStart(start.index, start.content_block);
    }

    if (event.type === "content_block_delta") {
      const delta = event as { index: number; delta: { type: string } };
      return this.onBlockDelta(delta.index, delta.delta);
    }

    if (event.type === "content_block_stop") {
      const stop = event as { index: number };
      const tracked = this.byStreamIndex.get(stop.index);
      if (tracked && !tracked.closed) {
        tracked.closed = true;
        return [
          { type: "blockUpdated", blockId: tracked.blockId, patch: { streaming: false } },
        ];
      }
      return [];
    }

    return [];
  }

  private onBlockStart(index: number, content: ClaudeContentBlock): AdapterEvent[] {
    if (content.type === "text") {
      const block: TranscriptBlock = {
        kind: "agentMessage",
        id: this.nextId(),
        text: "",
        streaming: true,
      };
      this.track(block.id, "agentMessage", null, index, false);
      return [{ type: "blockAppended", block }];
    }

    if (content.type === "thinking") {
      const block: TranscriptBlock = {
        kind: "reasoning",
        id: this.nextId(),
        text: "",
        streaming: true,
      };
      this.track(block.id, "reasoning", null, index, false);
      return [{ type: "blockAppended", block }];
    }

    if (content.type === "tool_use") {
      const tool = content as ClaudeToolUseBlock;
      const kind = classifyTool(tool.name);
      const block = buildToolBlock(this.nextId(), kind, tool, this.cwd);
      this.track(block.id, kind, tool.id ?? null, index, false);
      return [{ type: "blockAppended", block }];
    }

    return [];
  }

  private onBlockDelta(index: number, delta: { type: string }): AdapterEvent[] {
    const tracked = this.byStreamIndex.get(index);
    if (!tracked) return [];

    if (delta.type === "text_delta") {
      const text = (delta as { text?: string }).text ?? "";
      if (!text) return [];
      return [{ type: "blockUpdated", blockId: tracked.blockId, patch: { appendText: text } }];
    }

    if (delta.type === "thinking_delta") {
      const text = (delta as { thinking?: string }).thinking ?? "";
      if (!text) return [];
      return [{ type: "blockUpdated", blockId: tracked.blockId, patch: { appendText: text } }];
    }

    // input_json_delta 是工具参数的 JSON 分片，半截 JSON 上屏没有意义，
    // 等 assistant 整块帧给出解析结果再回填
    return [];
  }

  // MARK: - control_request

  private onControlRequest(message: ClaudeControlRequest): AdapterEvent[] {
    const body = message.request;
    if (!body || body.subtype !== "can_use_tool") return [];

    const request = body as ClaudeCanUseToolRequest;
    const kind = classifyTool(request.tool_name);
    const detail = approvalDetail(kind, request);
    const label = request.display_name ?? request.tool_name;

    return [
      {
        type: "approvalRequested",
        approval: {
          id: message.request_id,
          kind:
            kind === "shellCommand"
              ? "shellCommand"
              : kind === "fileChange"
                ? "fileChange"
                : "tool",
          title: condense(`${label}: ${request.description ?? detail}`, TITLE_MAX),
          detail,
          cwd: this.cwd,
          options: approvalOptions(request),
          requestedAtMs: this.now(),
        },
      },
      { type: "status", status: "awaitingApproval" },
    ];
  }

  // MARK: - result

  private onResult(message: ClaudeResult): AdapterEvent[] {
    const events: AdapterEvent[] = [];
    const usage = message.usage ?? {};

    if (message.is_error) {
      const detail = message.result ?? message.terminal_reason ?? "Claude turn failed";
      // assistant 帧已经把同一句报过并置过 error 态时，这里整个跳过，避免重复上屏
      if (detail !== this.lastFatalMessage) {
        events.push({ type: "error", message: detail, fatal: true });
        events.push({ type: "status", status: "error" });
      }
    }

    events.push({
      type: "turnCompleted",
      inputTokens: typeof usage.input_tokens === "number" ? usage.input_tokens : null,
      outputTokens: typeof usage.output_tokens === "number" ? usage.output_tokens : null,
      cachedInputTokens:
        typeof usage.cache_read_input_tokens === "number"
          ? usage.cache_read_input_tokens
          : null,
      stopReason: mapStopReason(message),
    });

    if (!message.is_error) {
      events.push({ type: "status", status: "idle" });
    }

    this.lastFatalMessage = null;
    return events;
  }

  // MARK: - 块登记

  private nextId(): string {
    this.seq += 1;
    return `${this.idPrefix}-blk-${this.seq}`;
  }

  private track(
    blockId: string,
    kind: TrackedKind,
    toolUseId: string | null,
    streamIndex: number | null,
    closed: boolean,
  ): void {
    const tracked: TrackedBlock = { blockId, kind, toolUseId, streamIndex, closed };
    if (streamIndex !== null) this.byStreamIndex.set(streamIndex, tracked);
    if (toolUseId !== null) this.byToolUseId.set(toolUseId, tracked);
    if (!closed) this.open.push(tracked);
  }

  /** tool_use 按 id 精确配对；text/thinking 只能按同种类里最早未收口的那个配 */
  private takeOpen(kind: TrackedKind, toolUseId: string | null): TrackedBlock | null {
    if (toolUseId !== null) {
      const byId = this.byToolUseId.get(toolUseId);
      return byId && !byId.closed ? byId : null;
    }
    const index = this.open.findIndex((b) => b.kind === kind && !b.closed);
    if (index === -1) return null;
    const found = this.open[index];
    if (!found) return null;
    this.open.splice(index, 1);
    return found;
  }
}

// MARK: - 纯辅助

function classifyTool(name: string): TrackedKind {
  if (name === "Bash") return "shellCommand";
  if (FILE_TOOLS.has(name)) return "fileChange";
  return "toolCall";
}

/** mcp__<server>__<tool> 里的 server 段；非 MCP 工具没有来源 */
function mcpSource(name: string): string | null {
  if (!name.startsWith("mcp__")) return null;
  const parts = name.split("__");
  return parts.length >= 2 && parts[1] ? parts[1] : null;
}

function buildToolBlock(
  id: string,
  kind: TrackedKind,
  tool: ClaudeToolUseBlock,
  cwd: string | null,
): TranscriptBlock {
  const input = tool.input ?? {};
  if (kind === "shellCommand") {
    return {
      kind: "shellCommand",
      id,
      command: stringField(input, "command"),
      cwd,
      output: "",
      exitCode: null,
      status: "running",
    };
  }
  if (kind === "fileChange") {
    const path = stringField(input, "file_path") || stringField(input, "notebook_path");
    // Claude 的 tool_use 只给路径和内容，增删行数无从得知，按契约必须是 null
    return {
      kind: "fileChange",
      id,
      files: path ? [{ path, added: null, removed: null }] : [],
      status: "running",
    };
  }
  return {
    kind: "toolCall",
    id,
    source: mcpSource(tool.name),
    tool: tool.name,
    summary: condense(toolSummary(tool), SUMMARY_MAX),
    output: "",
    status: "running",
  };
}

/** stream 开块时参数还是空的，assistant 整块帧到了再把参数补上 */
function describeToolInput(
  kind: TrackedKind,
  tool: ClaudeToolUseBlock,
  cwd: string | null,
): TranscriptBlockPatch | null {
  const input = tool.input ?? {};
  if (kind === "shellCommand") {
    const command = stringField(input, "command");
    return command ? { replaceText: command } : null;
  }
  if (kind === "fileChange") {
    const path = stringField(input, "file_path") || stringField(input, "notebook_path");
    return path ? { files: [{ path, added: null, removed: null }] } : null;
  }
  void cwd;
  const summary = condense(toolSummary(tool), SUMMARY_MAX);
  return summary ? { summary } : null;
}

function toolSummary(tool: ClaudeToolUseBlock): string {
  const input = tool.input ?? {};
  const description = stringField(input, "description");
  if (description) return description;
  const prompt = stringField(input, "prompt");
  if (prompt) return prompt;
  const path = stringField(input, "file_path") || stringField(input, "path");
  if (path) return path;
  const keys = Object.keys(input);
  return keys.length > 0 ? keys.join(", ") : tool.name;
}

function approvalDetail(kind: TrackedKind, request: ClaudeCanUseToolRequest): string {
  const input = request.input ?? {};
  if (kind === "shellCommand") {
    const command = stringField(input, "command");
    if (command) return command;
  }
  if (kind === "fileChange") {
    const path = stringField(input, "file_path") || stringField(input, "notebook_path");
    if (path) return path;
  }
  try {
    return JSON.stringify(input, null, 2);
  } catch {
    return request.tool_name;
  }
}

/**
 * scope 而不是 label 才是眼镜端区分"就这一次"和"永久放行"的依据，所以这里的
 * scope 必须对得上实际回送的裁决：
 *   once       → {behavior:"allow"}，只放行本次
 *   persistent → {behavior:"allow", updatedPermissions:<CLI 给的建议>}，会落盘成规则
 *
 * persistent 只在 CLI 给了 permission_suggestions 时才出——实测 Bash 给 addRules
 * （落 localSettings）、Write 给 setMode（切 acceptEdits）。没有建议还给这个选项，
 * 等于向用户承诺一个 adapter 兑现不了的作用域。
 *
 * Claude 没有"本会话内放行"这一档对应物，所以 scope "session" 不产出。
 * abort 走 deny + interrupt，interrupt 字段[依据文档]未实测。
 */
function approvalOptions(request: ClaudeCanUseToolRequest): ApprovalOption[] {
  const options: ApprovalOption[] = [
    { id: "allow", label: "允许", kind: "allow", scope: "once" },
  ];
  const suggestions = request.permission_suggestions;
  if (Array.isArray(suggestions) && suggestions.length > 0) {
    options.push({
      id: "allowAlways",
      label: "总是允许",
      kind: "allow",
      scope: "persistent",
    });
  }
  options.push({ id: "deny", label: "拒绝", kind: "deny", scope: "once" });
  options.push({ id: "abort", label: "拒绝并中断", kind: "abort", scope: "once" });
  return options;
}

/**
 * 映射到契约的 TurnStopReason。宁可给 null 也不猜：
 *
 *   terminal_reason "interrupted"  → interrupted  [依据 CLI 内嵌取值]，未实测
 *   is_error                       → failed       [实测] OAuth 过期那次
 *   stop_reason "max_tokens"       → maxTokens    [依据 Anthropic 规范]，未实测
 *   stop_reason "refusal"          → refused      [依据 Anthropic 规范]，未实测
 *   terminal_reason "completed" 或 stop_reason "end_turn" → completed  [实测]
 *
 * interrupted 排在 is_error 前面：中断大概率也会把 is_error 置起来，
 * 但"用户按了停"比"失败了"信息量大，不该被 failed 盖掉。
 * 注意判错只能看 is_error——实测 subtype 在鉴权失败时仍是 "success"。
 */
function mapStopReason(message: ClaudeResult): TurnStopReason | null {
  if (message.terminal_reason === "interrupted") return "interrupted";
  if (message.is_error) return "failed";

  const stop = message.stop_reason;
  if (stop === "max_tokens") return "maxTokens";
  if (stop === "refusal") return "refused";
  if (message.terminal_reason === "completed" || stop === "end_turn") return "completed";
  return null;
}

function toolResultText(block: ClaudeToolResultBlock): string {
  const content = block.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => part.text ?? "").join("");
}

function firstText(blocks: ClaudeContentBlock[]): string {
  for (const block of blocks) {
    if (block.type === "text") return (block as { text?: string }).text ?? "";
  }
  return "";
}

function stringField(input: Record<string, unknown>, key: string): string {
  const value = input[key];
  return typeof value === "string" ? value : "";
}

function condense(text: string, max: number): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}
