/**
 * JSON-RPC / ACP 请求超时：CLI 卡死时不能让 Promise 永远挂着把会话钉在 starting。
 * 错误前缀 `rpc_timeout:` 稳定，客户端与日志可按此前缀识别。
 */

/** initialize / 建会话类 RPC：冷启动、读历史可能较慢 */
export const RPC_TIMEOUT_START_MS = 60_000;

/** 其余 RPC 默认超时 */
export const RPC_TIMEOUT_DEFAULT_MS = 30_000;

/** 走较长超时的方法（handshake / session-create 风格） */
const START_STYLE_METHODS = new Set([
  "initialize",
  "thread/start",
  "thread/resume",
  "session/new",
  "session/load",
]);

export function rpcTimeoutMs(method: string): number {
  return START_STYLE_METHODS.has(method) ? RPC_TIMEOUT_START_MS : RPC_TIMEOUT_DEFAULT_MS;
}

/** 可注入的定时器，单测用假时钟推进而不真睡 */
export interface TimeoutTimers {
  setTimeout: (callback: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const defaultTimers: TimeoutTimers = {
  setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle as NodeJS.Timeout),
};

export interface WithTimeoutOptions {
  timers?: TimeoutTimers;
  /** 超时触发时回调（例如从 pending map 里摘掉该请求） */
  onTimeout?: () => void;
  /** 覆盖默认 `rpc_timeout: …` 文案；Claude 对齐 helper 时用来保持原有报错 */
  message?: string;
}

/**
 * 给任意 Promise 套超时。超时后 reject，前缀固定为 `rpc_timeout:`（除非传入 message）。
 */
export function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  label: string,
  options?: WithTimeoutOptions,
): Promise<T> {
  const timers = options?.timers ?? defaultTimers;
  const message = options?.message ?? `rpc_timeout: ${label} after ${ms}ms`;

  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const handle = timers.setTimeout(() => {
      if (settled) return;
      settled = true;
      options?.onTimeout?.();
      reject(new Error(message));
    }, ms);

    promise.then(
      (value) => {
        if (settled) return;
        settled = true;
        timers.clearTimeout(handle);
        resolve(value);
      },
      (error: unknown) => {
        if (settled) return;
        settled = true;
        timers.clearTimeout(handle);
        reject(error);
      },
    );
  });
}
