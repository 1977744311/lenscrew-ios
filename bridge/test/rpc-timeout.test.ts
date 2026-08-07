import test from "node:test";
import assert from "node:assert/strict";

import {
  RPC_TIMEOUT_DEFAULT_MS,
  RPC_TIMEOUT_START_MS,
  rpcTimeoutMs,
  withTimeout,
  type TimeoutTimers,
} from "../src/adapters/rpcTimeout.ts";

/** 可控假时钟：记录调度，按需手动触发，不真睡 */
function fakeTimers(): TimeoutTimers & {
  fireAll(): void;
  fireNext(): void;
  pending: Array<{ callback: () => void; ms: number }>;
} {
  const pending: Array<{ callback: () => void; ms: number; handle: symbol }> = [];
  return {
    pending,
    setTimeout(callback, ms) {
      const handle = Symbol("timer");
      pending.push({ callback, ms, handle });
      return handle;
    },
    clearTimeout(handle) {
      const index = pending.findIndex((entry) => entry.handle === handle);
      if (index >= 0) pending.splice(index, 1);
    },
    fireNext() {
      const next = pending.shift();
      next?.callback();
    },
    fireAll() {
      while (pending.length > 0) this.fireNext();
    },
  };
}

test("initialize / session-create 风格走 60s，其余 30s", () => {
  assert.equal(rpcTimeoutMs("initialize"), RPC_TIMEOUT_START_MS);
  assert.equal(rpcTimeoutMs("thread/start"), RPC_TIMEOUT_START_MS);
  assert.equal(rpcTimeoutMs("thread/resume"), RPC_TIMEOUT_START_MS);
  assert.equal(rpcTimeoutMs("session/new"), RPC_TIMEOUT_START_MS);
  assert.equal(rpcTimeoutMs("session/load"), RPC_TIMEOUT_START_MS);
  assert.equal(rpcTimeoutMs("turn/start"), RPC_TIMEOUT_DEFAULT_MS);
  assert.equal(rpcTimeoutMs("session/prompt"), RPC_TIMEOUT_DEFAULT_MS);
  assert.equal(rpcTimeoutMs("session/set_mode"), RPC_TIMEOUT_DEFAULT_MS);
});

test("withTimeout 在时限内兑现则清除定时器并返回值", async () => {
  const timers = fakeTimers();
  const result = await withTimeout(Promise.resolve(42), 1000, "probe", { timers });
  assert.equal(result, 42);
  assert.equal(timers.pending.length, 0);
});

test("withTimeout 超时以 rpc_timeout: 前缀拒绝，并触发 onTimeout", async () => {
  const timers = fakeTimers();
  let timedOut = false;
  const hung = new Promise<never>(() => {});
  const raced = withTimeout(hung, 500, "initialize", {
    timers,
    onTimeout: () => {
      timedOut = true;
    },
  });

  assert.equal(timers.pending.length, 1);
  assert.equal(timers.pending[0]!.ms, 500);
  timers.fireNext();

  await assert.rejects(raced, (error: unknown) => {
    assert.ok(error instanceof Error);
    assert.match(error.message, /^rpc_timeout: initialize after 500ms$/);
    return true;
  });
  assert.equal(timedOut, true);
});

test("withTimeout 可覆盖报错文案（对齐 Claude 原行为）", async () => {
  const timers = fakeTimers();
  const hung = new Promise<never>(() => {});
  const raced = withTimeout(hung, 15_000, "initialize", {
    timers,
    message: "claude 控制请求超时: initialize",
  });
  timers.fireNext();
  await assert.rejects(raced, /claude 控制请求超时: initialize/);
});

test("底层 Promise 先失败时清除定时器并透传错误", async () => {
  const timers = fakeTimers();
  const raced = withTimeout(Promise.reject(new Error("boom")), 1000, "turn/start", {
    timers,
  });
  await assert.rejects(raced, /boom/);
  assert.equal(timers.pending.length, 0);
});
