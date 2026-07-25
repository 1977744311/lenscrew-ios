// LensCrew 统一 agent 契约 —— bridge 与 iOS App 之间唯一的线上格式。
//
// 三个运行时的原生接口差异极大（2026-07-25 本机实测，见 README「运行时接口矩阵」）：
//   codex  0.144.4      codex app-server，JSON-RPC/stdio，审批是 server→client 请求
//   claude 2.1.215      claude -p --input-format stream-json，NDJSON，Anthropic 消息体
//   cursor 2026.07.23   cursor-agent acp，ACP JSON-RPC；-p 模式没有审批通道，会直接 rejected
// 差异只允许存在于 adapters/ 内部；越过本文件之后，客户端不应再关心 agent 种类，
// 只关心 capabilities 自陈的能力。
//
// Swift 侧 Sources/AgentProtocol/ 是本文件的同构镜像，两边共用
// protocol/fixtures/*.json 做往返测试，任何一侧改动而不同步都会让 fixture 测试变红。

export type AgentKind = "codex" | "claude" | "cursor";

/**
 * adapter 自陈的能力。客户端据此决定 UI（是否显示审批卡、计划模式开关、中断按钮），
 * 而不是按 agent 种类硬编码——同一个 agent 换驱动方式能力就会变，
 * 例如 cursor 走 acp 有审批、走 -p 就没有。
 */
export interface AgentCapabilities {
  /** 能把工具审批交给客户端裁决，而不是由 CLI 自行放行或拒绝 */
  approvals: boolean;
  /** turn 运行中可插入新指令且不打断当前 turn */
  steering: boolean;
  interrupt: boolean;
  /** 只读规划模式 */
  planMode: boolean;
  /** 可按原生会话 id 续接历史会话 */
  resume: boolean;
  /** 输出 token 级增量；false 表示只能整块拿到消息 */
  streamingDeltas: boolean;
}

export type SessionStatus =
  | "starting"
  | "idle"
  | "running"
  | "awaitingApproval"
  | "error"
  | "ended";

export interface AgentSession {
  /** bridge 分配，跨重连稳定 */
  id: string;
  agent: AgentKind;
  /** 运行时自己的会话 id（codex threadId / claude session_id / acp sessionId），用于续接 */
  nativeId: string | null;
  workspaceRoot: string;
  title: string;
  model: string | null;
  status: SessionStatus;
  capabilities: AgentCapabilities;
  createdAtMs: number;
  updatedAtMs: number;
}

// MARK: - 会话流水

export type BlockStatus = "pending" | "running" | "ok" | "failed" | "rejected";

export interface FileChangeSummary {
  path: string;
  added: number;
  removed: number;
}

export interface PlanStep {
  text: string;
  status: "pending" | "running" | "done";
}

/**
 * 会话流水的最小单元。三个运行时的原生条目都归一到这 8 类：
 * codex 的 ThreadItem 18 类、claude 的 content block、cursor 的 tool_call 变体
 * 都在 adapter 内折叠进来，折不进去的一律进 toolCall 兜底而不是新增类型。
 */
export type TranscriptBlock =
  | { kind: "userMessage"; id: string; text: string; imageCount: number }
  | { kind: "agentMessage"; id: string; text: string; streaming: boolean }
  | { kind: "reasoning"; id: string; text: string; streaming: boolean }
  | {
      kind: "shellCommand";
      id: string;
      command: string;
      cwd: string | null;
      output: string;
      exitCode: number | null;
      status: BlockStatus;
    }
  | {
      kind: "fileChange";
      id: string;
      files: FileChangeSummary[];
      status: BlockStatus;
    }
  | {
      kind: "toolCall";
      id: string;
      /** MCP server 名或工具来源；无来源时为 null */
      source: string | null;
      tool: string;
      summary: string;
      status: BlockStatus;
    }
  | { kind: "plan"; id: string; steps: PlanStep[] }
  | { kind: "error"; id: string; message: string };

/**
 * 增量更新。只带变化的字段——流式输出下 blockUpdated 的量远大于 blockAppended，
 * 而眼镜端每次刷新都是整屏替换，能省的带宽都要省。
 */
export interface TranscriptBlockPatch {
  /** 追加到 text/output 尾部；与 replaceText 互斥 */
  appendText?: string;
  replaceText?: string;
  streaming?: boolean;
  status?: BlockStatus;
  exitCode?: number;
  files?: FileChangeSummary[];
  steps?: PlanStep[];
}

// MARK: - 审批

export type ApprovalKind = "shellCommand" | "fileChange" | "tool" | "permission";

export type ApprovalOptionKind = "allow" | "allowAlways" | "deny" | "abort";

export interface ApprovalOption {
  id: string;
  label: string;
  kind: ApprovalOptionKind;
}

/**
 * 审批请求。title 是唯一保证能在 600×600 眼镜屏一行放下的字段，
 * detail 可能是整段命令或 diff，眼镜端要分页，手机端可整段展示。
 */
export interface ApprovalRequest {
  id: string;
  kind: ApprovalKind;
  title: string;
  detail: string;
  cwd: string | null;
  /** 由 adapter 给出——codex 支持 approved_for_session，acp 的选项由 agent 动态提供 */
  options: ApprovalOption[];
  requestedAtMs: number;
}

export type ApprovalOutcome = "resolved" | "cancelled" | "timedOut";

// MARK: - bridge → 客户端

/**
 * 每个事件带会话内单调递增的 seq。手机和眼镜都可能随时断线，
 * 重连时用 subscribe{fromSeq} 补齐而不是重拉整个会话。
 */
export type BridgeEvent =
  | { type: "sessionCreated"; seq: number; session: AgentSession }
  | {
      type: "sessionStatus";
      seq: number;
      sessionId: string;
      status: SessionStatus;
    }
  | { type: "sessionClosed"; seq: number; sessionId: string; reason: string }
  | {
      type: "blockAppended";
      seq: number;
      sessionId: string;
      block: TranscriptBlock;
    }
  | {
      type: "blockUpdated";
      seq: number;
      sessionId: string;
      blockId: string;
      patch: TranscriptBlockPatch;
    }
  | {
      type: "approvalRequested";
      seq: number;
      sessionId: string;
      approval: ApprovalRequest;
    }
  | {
      type: "approvalSettled";
      seq: number;
      sessionId: string;
      approvalId: string;
      optionId: string | null;
      outcome: ApprovalOutcome;
    }
  | {
      type: "turnCompleted";
      seq: number;
      sessionId: string;
      inputTokens: number | null;
      outputTokens: number | null;
    }
  | {
      type: "bridgeError";
      seq: number;
      sessionId: string | null;
      message: string;
      fatal: boolean;
    };

// MARK: - 客户端 → bridge

export type SessionMode = "default" | "plan";

export type ClientCommand =
  | { type: "listSessions" }
  | {
      type: "createSession";
      agent: AgentKind;
      workspaceRoot: string;
      model: string | null;
      mode: SessionMode;
    }
  | {
      type: "resumeSession";
      agent: AgentKind;
      nativeId: string;
      workspaceRoot: string;
    }
  | { type: "sendMessage"; sessionId: string; text: string }
  | { type: "interrupt"; sessionId: string }
  | {
      type: "resolveApproval";
      sessionId: string;
      approvalId: string;
      optionId: string;
    }
  | { type: "closeSession"; sessionId: string }
  | { type: "subscribe"; sessionId: string; fromSeq: number };
