// 无活跃 codex 会话时的额度探针。
//
// account/rateLimits/updated 只在 turn 进行中才会推送——不补数的话，
// 表盘/小组件上的额度会一直停在最后一次会话的数字上，重置了也看不出来。
// 探针短暂拉起 `codex app-server`，只走 initialize → account/rateLimits/read
// 就收工，不开 thread、不产生任何会话。

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

import { CodexNormalizer } from "../adapters/codex/normalizer.ts";
import type { AgentQuotaSnapshot } from "../protocol/events.ts";

export interface QuotaProbeTarget {
  ingestQuota(snapshot: AgentQuotaSnapshot): void;
  latestQuota(): AgentQuotaSnapshot[];
}

export interface QuotaProbeOptions {
  hub: QuotaProbeTarget;
  /** codex 可执行文件；默认走 PATH */
  command?: string;
  /** 校准周期；有会话在喂 updated 时到点会自动跳过 */
  intervalMs?: number;
  /** 首次探测延迟：`lenscrew qr` 这类短命进程不该拉起 codex */
  initialDelayMs?: number;
  /** 单次探测的硬超时 */
  timeoutMs?: number;
  log?: (line: string) => void;
}

export interface QuotaProbeHandle {
  close(): void;
}

const DEFAULT_INTERVAL_MS = 30 * 60_000;
const DEFAULT_INITIAL_DELAY_MS = 3_000;
const DEFAULT_TIMEOUT_MS = 15_000;

/**
 * 单次探测：拉起 app-server、读一次额度、杀进程。
 * 拿不到（codex 未安装、旧版无此方法、超时）一律返回 null——
 * 额度是锦上添花，绝不能因为它把 bridge 弄出错误噪音。
 */
export async function probeQuotaOnce(
  command: string,
  timeoutMs: number,
): Promise<AgentQuotaSnapshot | null> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(command, ["app-server"], { stdio: ["pipe", "pipe", "ignore"] });
    } catch {
      resolve(null);
      return;
    }

    let settled = false;
    const finish = (snapshot: AgentQuotaSnapshot | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill("SIGTERM");
      resolve(snapshot);
    };
    const timer = setTimeout(() => finish(null), timeoutMs);
    timer.unref();

    child.on("error", () => finish(null));
    child.on("exit", () => finish(null));

    const write = (payload: unknown): void => {
      if (child.stdin === null || child.stdin.destroyed) return;
      child.stdin.write(`${JSON.stringify(payload)}\n`);
    };

    if (child.stdout === null) {
      finish(null);
      return;
    }
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => {
      let message: { id?: unknown; result?: unknown; error?: unknown };
      try {
        message = JSON.parse(line) as typeof message;
      } catch {
        return;
      }
      if (message.id === 1 && message.error === undefined) {
        write({ jsonrpc: "2.0", method: "initialized" });
        write({ jsonrpc: "2.0", id: 2, method: "account/rateLimits/read", params: {} });
        return;
      }
      if (message.id === 2) {
        if (message.error !== undefined || message.result === undefined) {
          finish(null);
          return;
        }
        // 归一逻辑与会话 adapter 共用同一份，探针不自立门户
        const events = new CodexNormalizer().normalizeRateLimitsRead(message.result);
        const quota = events.find((event) => event.type === "quotaUpdated");
        finish(quota !== undefined && quota.type === "quotaUpdated" ? quota.quota : null);
      }
    });

    write({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        clientInfo: { name: "lenscrew-quota-probe", title: "LensCrew", version: "0.0.1" },
        capabilities: null,
      },
    });
  });
}

export function startQuotaProbe(options: QuotaProbeOptions): QuotaProbeHandle {
  const command = options.command ?? "codex";
  const intervalMs = options.intervalMs ?? DEFAULT_INTERVAL_MS;
  const initialDelayMs = options.initialDelayMs ?? DEFAULT_INITIAL_DELAY_MS;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const log = options.log ?? (() => {});

  let closed = false;
  let failures = 0;

  const isFresh = (): boolean => {
    const codex = options.hub
      .latestQuota()
      .find((snapshot) => snapshot.agent === "codex");
    return codex !== undefined && Date.now() - codex.capturedAtMs < intervalMs;
  };

  const tick = async (): Promise<void> => {
    if (closed || isFresh()) return;
    const snapshot = await probeQuotaOnce(command, timeoutMs);
    if (closed) return;
    if (snapshot !== null) {
      failures = 0;
      options.hub.ingestQuota(snapshot);
      return;
    }
    failures += 1;
    // codex 未安装或版本过旧时每次都会失败，连败三次就收手别再拉进程了
    if (failures === 3) {
      log("codex 额度探针连续失败，已停用（codex 未安装或版本不支持）");
      close();
    }
  };

  const interval = setInterval(() => void tick(), intervalMs);
  interval.unref();
  const initial = setTimeout(() => void tick(), initialDelayMs);
  initial.unref();

  const close = (): void => {
    closed = true;
    clearInterval(interval);
    clearTimeout(initial);
  };

  return { close };
}
