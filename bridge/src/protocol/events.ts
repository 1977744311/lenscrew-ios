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

/**
 * 会话模式的一个档位。id 属于各 adapter 自己的命名空间
 * （codex: plan/default/auto/full，claude: plan/default/acceptEdits/bypass，
 * cursor: agent/plan/ask），客户端只展示、不解释——语义差异是各运行时
 * 真实存在的，硬拉齐三家反而是在撒谎。
 */
export interface SessionModeOption {
  id: string;
  label: string;
  /** 一句话说明这一档批什么、放什么（选择器副文本） */
  detail: string;
}

/**
 * 会话可用的一个模型。id 是运行时自己的模型标识（codex "gpt-5.6-terra"、
 * claude "sonnet"、cursor "gpt-5.4-mini[reasoning=medium]"），label 是人读名。
 * 清单由运行时自陈（claude init、cursor session/new、codex model/list），
 * bridge 不维护静态模型表——上游上新时这里自动跟上。
 */
export interface SessionModelOption {
  id: string;
  label: string;
  /**
   * 该模型支持的推理档（codex 的 model/list 自陈，如 low/medium/high/xhigh）。
   * 空数组表示不支持推理档选择——cursor 的档位编死在模型 id 的参数里
   * （实测 set_config_option 拒绝自定义参数组合），claude 没有档位概念。
   */
  reasoningEfforts: string[];
}

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
  /**
   * 当前审批/协作模式。初值由 adapter 给出，之后跟随运行时回显
   * （claude 的 system/status、cursor 的 current_mode_update）；
   * 运行时没有模式概念时为 null。
   */
  modeId: string | null;
  /** 本会话可切换的模式清单；空数组表示不支持切换 */
  modes: SessionModeOption[];
  /** 本会话可切换的模型清单（运行时自陈）；空数组表示不支持切换 */
  models: SessionModelOption[];
  /** 当前推理档；null 表示跟随 CLI 默认或运行时无档位概念 */
  reasoningEffort: string | null;
  createdAtMs: number;
  updatedAtMs: number;
}

// MARK: - 会话流水

export type BlockStatus = "pending" | "running" | "ok" | "failed" | "rejected";

export interface FileChangeSummary {
  path: string;
  /**
   * 增删行数。不是所有运行时都给得出：claude 的 tool_use 只有路径和内容，
   * 拿不到就必须是 null——填 0 会让客户端显示 "+0 −0"，那是在撒谎。
   */
  added: number | null;
  removed: number | null;
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
      /** 一行摘要，眼镜屏上通常只显示这个 */
      summary: string;
      /** 工具返回的正文。眼镜端用不上，但手机端要看，adapter 不应在边界上丢掉 */
      output: string;
      status: BlockStatus;
    }
  | { kind: "plan"; id: string; steps: PlanStep[] }
  | { kind: "error"; id: string; message: string };

/**
 * 增量更新。只带变化的字段——流式输出下 blockUpdated 的量远大于 blockAppended，
 * 而眼镜端每次刷新都是整屏替换，能省的带宽都要省。
 *
 * `appendText` / `replaceText` 作用在**每种块各自的主文本字段**上，
 * 不写清楚已经有两个实现读错了：
 *
 *   userMessage / agentMessage / reasoning → text
 *   shellCommand                           → output
 *   toolCall                               → output（摘要走 summary 字段）
 *   error                                  → message
 *   fileChange / plan                      → 无主文本，两个字段都会被忽略
 */
export interface TranscriptBlockPatch {
  /** 追加到主文本尾部；与 replaceText 互斥 */
  appendText?: string;
  replaceText?: string;
  streaming?: boolean;
  status?: BlockStatus;
  exitCode?: number;
  /** 只对 shellCommand 有意义。有的运行时到命令结束才给得出工作目录 */
  cwd?: string;
  /** 只对 toolCall 有意义 */
  summary?: string;
  files?: FileChangeSummary[];
  steps?: PlanStep[];
}

// MARK: - 审批

export type ApprovalKind = "shellCommand" | "fileChange" | "tool" | "permission";

export type ApprovalOptionKind = "allow" | "deny" | "abort";

/**
 * 裁决的作用范围。三个运行时都区分这三档，而且差别是安全性的而非便利性的：
 * codex 的 acceptForSession 与 acceptWithExecpolicyAmendment（永久写进 execpolicy）、
 * ACP 的 allow_once 与 allow_always、claude 的 allow 与 updatedPermissions。
 * 眼镜上用户是在 600×600 屏上按按钮，"永久放行"和"就这一次"必须一眼可辨，
 * 不能只靠 label 文案——label 是给人读的，不该拿来做逻辑判断。
 */
export type ApprovalScope = "once" | "session" | "persistent";

export interface ApprovalOption {
  id: string;
  label: string;
  kind: ApprovalOptionKind;
  scope: ApprovalScope;
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

/**
 * turn 的结束原因。被 token 上限截断和正常说完在客户端看来是两回事，
 * 只给一个 turnCompleted 会把它们抹平。运行时给不出时为 null。
 */
export type TurnStopReason =
  | "completed"
  | "interrupted"
  | "maxTokens"
  | "refused"
  | "failed";

// MARK: - 账号额度

/**
 * 一个滚动额度窗口。标签显示名必须由 windowDurationMins 推导（5h/周/…），
 * 不能按 primary/secondary 位置硬编码——实测有账号只有一个 10080 分钟的
 * primary 窗口而没有 secondary，"primary=5h" 的假设直接就是错的。
 */
export interface QuotaWindow {
  /** 跨快照稳定的窗口标识：`<limitId>/primary` 或 `<limitId>/secondary` */
  id: string;
  /** 运行时给的人读名（模型专属桶才有）；null 时客户端按窗口时长推导显示名 */
  label: string | null;
  /** wire 原值不钳位，显示层自行 clamp 到 0–100 */
  usedPercent: number;
  windowDurationMins: number | null;
  /** unix 秒 */
  resetsAt: number | null;
}

/**
 * 账号级额度快照。只有 codex 有程序化通道（account/rateLimits/read + updated），
 * claude 的 stream-json 与 cursor 的 ACP 都拿不到账号额度，
 * 所以 agent 目前恒为 "codex"——但契约不为单一实现收窄类型。
 */
export interface AgentQuotaSnapshot {
  agent: AgentKind;
  planType: string | null;
  windows: QuotaWindow[];
  /** bridge 收到该快照的时刻；客户端据此显示数据新鲜度 */
  capturedAtMs: number;
}

// MARK: - bridge → 客户端

/**
 * 每个事件带会话内单调递增的 seq。手机和眼镜都可能随时断线，
 * 重连时用 subscribe{fromSeq} 补齐而不是重拉整个会话。
 */
export type BridgeEvent =
  | { type: "sessionCreated"; seq: number; session: AgentSession }
  /**
   * 会话元数据快照刷新：标题、model、nativeId、capabilities。
   *
   * capabilities 尤其需要它：几个 adapter 的真实能力要到 start() 之后才知道
   * （claude 的 approvals 取决于启动参数，cursor 的 resume 要等 ACP 握手自陈），
   * 而 sessionCreated 必须在 start() 之前发出去，否则启动期间的事件没有归属。
   * 客户端收到本事件应当只替换会话元数据，保留已有流水。
   */
  | { type: "sessionUpdated"; seq: number; session: AgentSession }
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
      /** 缓存命中的 input token。实测一轮 24682 个 input 里 23296 是缓存，
       *  不单列出来客户端算出的成本会差一个数量级 */
      cachedInputTokens: number | null;
      stopReason: TurnStopReason | null;
    }
  | {
      type: "bridgeError";
      seq: number;
      sessionId: string | null;
      message: string;
      fatal: boolean;
    }
  /**
   * 账号级事件，不属于任何会话：seq 恒为 0，不进重放窗口也不参与断档补齐
   * （与首连时补发的合成 sessionCreated 同一先例）。客户端只保留最新一份。
   */
  | { type: "quotaUpdated"; seq: number; quota: AgentQuotaSnapshot };

// MARK: - 客户端 → bridge

export type ClientCommand =
  | { type: "listSessions" }
  | {
      type: "createSession";
      agent: AgentKind;
      workspaceRoot: string;
      model: string | null;
      /** 见 SessionModeOption.id；null 用 adapter 的缺省档 */
      modeId: string | null;
      /** 推理档；null 跟随 CLI 默认（仅 codex 有档位概念） */
      reasoningEffort: string | null;
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
  /** 会话中切换模式；codex 下一轮 turn 生效，claude/cursor 即时生效 */
  | { type: "setSessionMode"; sessionId: string; modeId: string }
  /** 会话中切换模型；codex 下一轮 turn 生效，claude/cursor 即时生效 */
  | { type: "setSessionModel"; sessionId: string; modelId: string }
  /** 会话中切换推理档；codex 下一轮 turn 生效（仅 codex 支持） */
  | { type: "setSessionReasoningEffort"; sessionId: string; effort: string }
  | { type: "closeSession"; sessionId: string }
  | { type: "subscribe"; sessionId: string; fromSeq: number };
