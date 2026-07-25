import type { TranscriptBlockPatch } from "../../protocol/events.ts";
import type { AdapterEvent, ProtocolNormalizer } from "../types.ts";
import type {
  CursorPrintContentBlock,
  CursorPrintMessage,
  CursorPrintToolCallPayload,
} from "./protocol.ts";

const TOOL_VARIANT_SUFFIX = "ToolCall";

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const textOf = (content: CursorPrintContentBlock[]): string =>
  content
    .filter((block) => block.type === "text")
    .map((block) => block.text ?? "")
    .join("");

const imageCountOf = (content: CursorPrintContentBlock[]): number =>
  content.filter((block) => block.type === "image").length;

/** shell 之外的工具只能靠 xxxToolCall 键名认出来，见 protocol.ts 的说明 */
const toolVariantOf = (
  payload: CursorPrintToolCallPayload,
): { tool: string; value: unknown } => {
  for (const [key, value] of Object.entries(payload)) {
    if (key.endsWith(TOOL_VARIANT_SUFFIX)) {
      return { tool: key.slice(0, -TOOL_VARIANT_SUFFIX.length), value };
    }
  }
  return { tool: "unknown", value: undefined };
};

const descriptionOf = (variant: unknown): string => {
  if (isRecord(variant) && typeof variant["description"] === "string") {
    return variant["description"];
  }
  return "";
};

/**
 * 路径 A（cursor-agent -p --output-format stream-json）的归一化器。
 *
 * 有内部状态：思考链是无 id 的增量，必须自己攒出块 id 才能把后续 delta 打回同一个块。
 * 状态只依赖消息先后顺序，不碰进程和网络，所以对着 fixture 逐行喂仍是确定性的。
 */
export class CursorPrintNormalizer implements ProtocolNormalizer<CursorPrintMessage> {
  #blockSeq = 0;
  #reasoningBlockId: string | null = null;

  normalize(message: CursorPrintMessage): AdapterEvent[] {
    switch (message.type) {
      case "system":
        return this.#onSystem(message);
      case "user":
        return this.#onUser(message);
      case "thinking":
        return this.#onThinking(message);
      case "assistant":
        return this.#onAssistant(message);
      case "tool_call":
        return this.#onToolCall(message);
      case "result":
        return this.#onResult(message);
      default:
        return [];
    }
  }

  #nextBlockId(prefix: string): string {
    this.#blockSeq += 1;
    return `${prefix}-${this.#blockSeq}`;
  }

  #closeReasoning(): AdapterEvent[] {
    const blockId = this.#reasoningBlockId;
    if (blockId === null) return [];
    this.#reasoningBlockId = null;
    return [{ type: "blockUpdated", blockId, patch: { streaming: false } }];
  }

  #onSystem(message: Extract<CursorPrintMessage, { type: "system" }>): AdapterEvent[] {
    if (message.subtype !== "init") return [];
    const events: AdapterEvent[] = [];
    if (message.session_id !== undefined) {
      events.push({ type: "nativeIdAssigned", nativeId: message.session_id });
    }
    if (message.model !== undefined) {
      events.push({ type: "modelResolved", model: message.model });
    }
    // init 只在一次 -p 调用启动时出现，等价于「这一轮开始跑了」
    events.push({ type: "status", status: "running" });
    return events;
  }

  #onUser(message: Extract<CursorPrintMessage, { type: "user" }>): AdapterEvent[] {
    const content = message.message.content;
    return [
      {
        type: "blockAppended",
        block: {
          kind: "userMessage",
          id: this.#nextBlockId("user"),
          text: textOf(content),
          imageCount: imageCountOf(content),
        },
      },
    ];
  }

  #onThinking(message: Extract<CursorPrintMessage, { type: "thinking" }>): AdapterEvent[] {
    if (message.subtype === "completed") return this.#closeReasoning();
    const text = message.text;
    if (text === undefined || text === "") return [];
    const openId = this.#reasoningBlockId;
    if (openId !== null) {
      return [{ type: "blockUpdated", blockId: openId, patch: { appendText: text } }];
    }
    const id = this.#nextBlockId("reasoning");
    this.#reasoningBlockId = id;
    return [
      { type: "blockAppended", block: { kind: "reasoning", id, text, streaming: true } },
    ];
  }

  #onAssistant(message: Extract<CursorPrintMessage, { type: "assistant" }>): AdapterEvent[] {
    const text = textOf(message.message.content);
    if (text === "") return [];
    const events = this.#closeReasoning();
    events.push({
      type: "blockAppended",
      block: {
        kind: "agentMessage",
        id: this.#nextBlockId("message"),
        text,
        streaming: false,
      },
    });
    return events;
  }

  #onToolCall(message: Extract<CursorPrintMessage, { type: "tool_call" }>): AdapterEvent[] {
    // 用原生 call_id 当块 id，started 与 completed 天然对得上，不用再维护映射
    const blockId = message.call_id;
    const payload = message.tool_call;
    const shell = payload.shellToolCall;

    if (message.subtype === "started") {
      const events = this.#closeReasoning();
      if (shell !== undefined) {
        const args = shell.args;
        const workingDirectory = args?.workingDirectory;
        events.push({
          type: "blockAppended",
          block: {
            kind: "shellCommand",
            id: blockId,
            command: args?.command ?? "",
            // [实测] started 时 workingDirectory 是空串，真实路径要等 result；
            // 而 TranscriptBlockPatch 没有 cwd 字段，补不回来，只能留 null
            cwd: workingDirectory ? workingDirectory : null,
            output: "",
            exitCode: null,
            status: "running",
          },
        });
        return events;
      }
      const variant = toolVariantOf(payload);
      events.push({
        type: "blockAppended",
        block: {
          kind: "toolCall",
          id: blockId,
          source: null,
          tool: variant.tool,
          summary: descriptionOf(variant.value),
          output: "",
          status: "running",
        },
      });
      return events;
    }

    const patch: TranscriptBlockPatch = {};
    if (shell !== undefined) {
      const rejected = shell.result?.rejected;
      const success = shell.result?.success;
      // started 时 workingDirectory 恒为空串，真实路径只在 result 里露一次，
      // 现在契约的 patch 有 cwd 字段，补得回去了
      const workingDirectory = rejected?.workingDirectory ?? success?.workingDirectory;
      if (workingDirectory) patch.cwd = workingDirectory;
      if (rejected !== undefined) {
        patch.status = "rejected";
        if (rejected.reason) patch.appendText = rejected.reason;
      } else if (success !== undefined) {
        const exitCode = success.exitCode;
        if (typeof exitCode === "number") patch.exitCode = exitCode;
        patch.status = typeof exitCode === "number" && exitCode !== 0 ? "failed" : "ok";
        const output =
          success.interleavedOutput ?? `${success.stdout ?? ""}${success.stderr ?? ""}`;
        if (output !== "") patch.appendText = output;
      } else {
        patch.status = "failed";
      }
    } else {
      // 非 shell 变体的 result 形状未实测。rejected 是 CLI 表达「审批被拒」的统一写法，
      // 认它一个就够避免把被拒当成成功——这正是契约里点名不能出的错。
      const variant = toolVariantOf(payload);
      const result = isRecord(variant.value) ? variant.value["result"] : undefined;
      patch.status = isRecord(result) && "rejected" in result ? "rejected" : "ok";
    }
    return [{ type: "blockUpdated", blockId, patch }];
  }

  #onResult(message: Extract<CursorPrintMessage, { type: "result" }>): AdapterEvent[] {
    const events = this.#closeReasoning();
    if (message.is_error) {
      events.push({ type: "error", message: message.result, fatal: false });
    }
    events.push({
      type: "turnCompleted",
      inputTokens: message.usage?.inputTokens ?? null,
      outputTokens: message.usage?.outputTokens ?? null,
      cachedInputTokens: message.usage?.cacheReadTokens ?? null,
      // -p 只有「跑完了」和「出错了」两种收场：被打断时它根本不吐 result 行（实测），
      // interrupted 由 adapter 在子进程退出时补
      stopReason: message.is_error ? "failed" : "completed",
    });
    events.push({ type: "status", status: message.is_error ? "error" : "idle" });
    return events;
  }
}
