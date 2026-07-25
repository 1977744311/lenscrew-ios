// 纯逻辑推送决策器:BridgeEvent + 已注册 token 表 → 待发送数组。
// 不做任何 I/O;由调用方拿 ApnsClient 按 environment 逐条发送。

import type { ApprovalOption, BridgeEvent, TurnStopReason } from "../protocol/events.ts";
import type { ApnsEnvironment } from "./apnsClient.ts";

export interface PushAlertToggles {
  approvals: boolean;
  turns: boolean;
}

export interface RegisteredPushToken {
  deviceToken: string;
  environment: ApnsEnvironment;
  alertsEnabled: PushAlertToggles;
}

/** key = phoneDeviceId */
export type PushTokenRegistry = Record<string, RegisteredPushToken>;

export interface OutgoingPush {
  phoneDeviceId: string;
  deviceToken: string;
  environment: ApnsEnvironment;
  payload: Record<string, unknown>;
}

export interface PushDispatchContext {
  /** turnCompleted 的通知标题;传不进来就用「轮次结束」 */
  sessionTitle?: string;
  /** 锁屏 action 直接批准/拒绝时,手机要知道回哪台 Mac */
  macDeviceId?: string;
}

/**
 * 从审批选项里挑出「允许一次」和「拒绝」的 optionId,塞进推送。
 * 手机在锁屏点 action 时不必先拉会话就能回 resolveApproval——
 * 没有 once 档就退而取任意 allow,给不出就整个省略,让手机走进 App 兜底。
 */
function decisionOptionIds(options: readonly ApprovalOption[]): {
  onceAllowOptionId?: string;
  denyOptionId?: string;
} {
  const allow =
    options.find((o) => o.kind === "allow" && o.scope === "once") ??
    options.find((o) => o.kind === "allow");
  const deny = options.find((o) => o.kind === "deny");
  return {
    ...(allow !== undefined && { onceAllowOptionId: allow.id }),
    ...(deny !== undefined && { denyOptionId: deny.id }),
  };
}

const ALERT_BODY_MAX = 160;

const TURN_STOP_BODY: Record<TurnStopReason, string> = {
  completed: "轮次完成",
  interrupted: "已中断",
  maxTokens: "达到 token 上限",
  refused: "被拒绝",
  failed: "轮次失败",
};

export class PushDispatcher {
  // approvalRequested 可能因重连补发重放,同一 approvalId 只推一次
  #sentApprovalIds = new Set<string>();
  #goneTokens = new Set<string>();

  dispatch(
    event: BridgeEvent,
    tokens: PushTokenRegistry,
    context: PushDispatchContext = {},
  ): OutgoingPush[] {
    switch (event.type) {
      case "approvalRequested": {
        if (this.#sentApprovalIds.has(event.approval.id)) return [];
        this.#sentApprovalIds.add(event.approval.id);
        return this.#collect(tokens, (token) => token.alertsEnabled.approvals, {
          aps: {
            alert: {
              title: event.approval.title,
              body: truncateForAlert(event.approval.detail),
            },
            sound: "default",
            "thread-id": event.sessionId,
            "interruption-level": "time-sensitive",
            category: "LENSCREW_APPROVAL",
          },
          lenscrew: {
            kind: "approval",
            sessionId: event.sessionId,
            approvalId: event.approval.id,
            ...(context.macDeviceId !== undefined && { macDeviceId: context.macDeviceId }),
            ...decisionOptionIds(event.approval.options),
          },
        });
      }
      case "turnCompleted": {
        const body = event.stopReason === null ? "轮次结束" : TURN_STOP_BODY[event.stopReason];
        return this.#collect(tokens, (token) => token.alertsEnabled.turns, {
          aps: {
            alert: { title: context.sessionTitle ?? "轮次结束", body },
            category: "LENSCREW_TURN",
          },
          lenscrew: {
            kind: "turn",
            sessionId: event.sessionId,
            stopReason: event.stopReason,
            ...(context.macDeviceId !== undefined && { macDeviceId: context.macDeviceId }),
          },
        });
      }
      case "bridgeError": {
        // 非致命错误会走会话流水,只有 fatal 才值得打扰全部手机
        if (!event.fatal) return [];
        return this.#collect(tokens, () => true, {
          aps: {
            alert: { title: "bridge 出错", body: truncateForAlert(event.message) },
          },
          lenscrew: { kind: "bridgeError", sessionId: event.sessionId },
        });
      }
      default:
        return [];
    }
  }

  /** 上层在收到 410/BadDeviceToken 后调用,之后的分发不再包含该 token */
  markTokenGone(deviceToken: string): void {
    this.#goneTokens.add(deviceToken);
  }

  #collect(
    tokens: PushTokenRegistry,
    wants: (token: RegisteredPushToken) => boolean,
    payload: Record<string, unknown>,
  ): OutgoingPush[] {
    const out: OutgoingPush[] = [];
    for (const [phoneDeviceId, token] of Object.entries(tokens)) {
      if (this.#goneTokens.has(token.deviceToken) || !wants(token)) continue;
      out.push({
        phoneDeviceId,
        deviceToken: token.deviceToken,
        environment: token.environment,
        payload,
      });
    }
    return out;
  }
}

export function createPushDispatcher(): PushDispatcher {
  return new PushDispatcher();
}

/** APNs alert body 按码点截断,避免劈开代理对 */
export function truncateForAlert(text: string): string {
  const points = [...text];
  return points.length <= ALERT_BODY_MAX ? text : points.slice(0, ALERT_BODY_MAX).join("");
}
