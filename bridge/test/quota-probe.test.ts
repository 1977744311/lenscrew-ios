import test from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { probeQuotaOnce, startQuotaProbe } from "../src/session/quotaProbe.ts";
import type { AgentQuotaSnapshot } from "../src/protocol/events.ts";

/** 一个只会应答 initialize 与 rateLimits/read 的假 app-server，供探针拉起 */
function fakeCodex(readResult: unknown): string {
  const dir = mkdtempSync(join(tmpdir(), "lenscrew-quota-probe-"));
  const path = join(dir, "fake-codex");
  const script = [
    "#!/usr/bin/env node",
    'import { createInterface } from "node:readline";',
    "const rl = createInterface({ input: process.stdin });",
    'rl.on("line", (line) => {',
    "  const msg = JSON.parse(line);",
    "  if (msg.id === 1) {",
    '    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\\n");',
    "  }",
    "  if (msg.id === 2) {",
    `    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 2, result: ${JSON.stringify(
      readResult,
    )} }) + "\\n");`,
    "  }",
    "});",
    "",
  ].join("\n");
  writeFileSync(path, script);
  chmodSync(path, 0o755);
  return path;
}

const READ_RESULT = {
  rateLimits: {
    limitId: "codex",
    limitName: null,
    planType: "pro",
    primary: { usedPercent: 37, windowDurationMins: 10080, resetsAt: 1785640649 },
    secondary: null,
  },
};

test("探针走完握手拿到额度快照并收掉进程", async () => {
  const snapshot = await probeQuotaOnce(fakeCodex(READ_RESULT), 5_000);
  assert.ok(snapshot);
  assert.equal(snapshot.agent, "codex");
  assert.equal(snapshot.planType, "pro");
  assert.deepEqual(
    snapshot.windows.map((window) => [window.id, window.usedPercent]),
    [["codex/primary", 37]],
  );
});

test("codex 不存在或响应报错时返回 null 而不是抛错", async () => {
  assert.equal(await probeQuotaOnce("/nonexistent/codex", 2_000), null);
  assert.equal(await probeQuotaOnce(fakeCodex({}), 2_000), null);
});

test("缓存过期时定时探针补数入库", async () => {
  const ingested: AgentQuotaSnapshot[] = [];
  const hub = {
    ingestQuota: (snapshot: AgentQuotaSnapshot) => ingested.push(snapshot),
    // 永远报告"没有缓存"：每个周期都该探
    latestQuota: () => [],
  };
  const probe = startQuotaProbe({
    hub,
    command: fakeCodex(READ_RESULT),
    initialDelayMs: 0,
    intervalMs: 120,
    timeoutMs: 5_000,
  });
  try {
    for (let waited = 0; ingested.length === 0 && waited < 5_000; waited += 50) {
      await sleep(50);
    }
    assert.ok(ingested.length >= 1, "过期缓存触发补数");
    assert.equal(ingested[0]!.windows[0]!.usedPercent, 37);
  } finally {
    probe.close();
  }
});

test("会话喂着新鲜数据时探针一次进程都不拉", async () => {
  let probed = 0;
  const hub = {
    ingestQuota: () => {
      probed += 1;
    },
    latestQuota: (): AgentQuotaSnapshot[] => [
      { agent: "codex", planType: null, windows: [], capturedAtMs: Date.now() },
    ],
  };
  const probe = startQuotaProbe({
    hub,
    command: fakeCodex(READ_RESULT),
    initialDelayMs: 0,
    intervalMs: 60,
    timeoutMs: 5_000,
  });
  try {
    await sleep(300);
    assert.equal(probed, 0);
  } finally {
    probe.close();
  }
});

test("连续失败三次后停用并留一条日志", async () => {
  const lines: string[] = [];
  const probe = startQuotaProbe({
    hub: { ingestQuota: () => {}, latestQuota: () => [] },
    command: "/nonexistent/codex",
    initialDelayMs: 0,
    intervalMs: 40,
    timeoutMs: 500,
    log: (line) => lines.push(line),
  });
  try {
    for (let waited = 0; lines.length === 0 && waited < 5_000; waited += 50) {
      await sleep(50);
    }
    assert.ok(lines.some((line) => line.includes("已停用")), `实际日志: ${lines.join(" / ")}`);
  } finally {
    probe.close();
  }
});
