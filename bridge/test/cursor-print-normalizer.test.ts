import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { CursorAdapter } from "../src/adapters/cursor/adapter.ts";
import { CursorPrintNormalizer } from "../src/adapters/cursor/printNormalizer.ts";
import type { CursorPrintMessage } from "../src/adapters/cursor/protocol.ts";
import type { AdapterEvent } from "../src/adapters/types.ts";

const FIXTURE = new URL("../../protocol/fixtures/cursor-print-turn.jsonl", import.meta.url);

const runFixture = (): AdapterEvent[] => {
  const normalizer = new CursorPrintNormalizer();
  return readFileSync(FIXTURE, "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "")
    .flatMap((line) => normalizer.normalize(JSON.parse(line) as CursorPrintMessage));
};

const summarize = (event: AdapterEvent): string => {
  switch (event.type) {
    case "blockAppended":
      return `blockAppended:${event.block.kind}`;
    case "blockUpdated":
      return `blockUpdated:${Object.keys(event.patch).join("+")}`;
    case "status":
      return `status:${event.status}`;
    default:
      return event.type;
  }
};

/** 把连续相同的事件折叠成「xxx ×n」，好让期望值读起来还是一条时间线 */
const shapeOf = (events: AdapterEvent[]): string[] => {
  const shape: string[] = [];
  let run = 0;
  let previous = "";
  for (const event of events) {
    const current = summarize(event);
    if (current === previous) {
      run += 1;
      shape[shape.length - 1] = `${current} ×${run}`;
      continue;
    }
    previous = current;
    run = 1;
    shape.push(current);
  }
  return shape;
};

test("-p 整轮流水归一成契约事件序列", () => {
  assert.deepEqual(shapeOf(runFixture()), [
    "nativeIdAssigned",
    "modelResolved",
    "status:running",
    "blockAppended:userMessage",
    "blockAppended:reasoning",
    "blockUpdated:appendText",
    "blockUpdated:streaming",
    "blockAppended:agentMessage",
    "blockAppended:shellCommand",
    "blockUpdated:status",
    "blockAppended:reasoning",
    "blockUpdated:appendText ×2",
    "blockUpdated:streaming",
    "blockAppended:agentMessage",
    "turnCompleted",
    "status:idle",
  ]);
});

test("init 带出原生会话 id 和模型", () => {
  const events = runFixture();
  assert.deepEqual(events[0], {
    type: "nativeIdAssigned",
    nativeId: "c73b9d8d-3a49-4022-b8e0-3863c46623d5",
  });
  assert.deepEqual(events[1], { type: "modelResolved", model: "Fable 5 1M Max" });
});

test("shell 调用先落 running 块，命令与工作目录按实测取值", () => {
  const appended = runFixture().find(
    (event) => event.type === "blockAppended" && event.block.kind === "shellCommand",
  );
  assert.deepEqual(appended, {
    type: "blockAppended",
    block: {
      kind: "shellCommand",
      id: "toolu_013Tf42Uwp4SvFNusCYUaPkT",
      command: "echo lenscrew-probe",
      // started 时 CLI 给的 workingDirectory 是空串，只能是 null
      cwd: null,
      output: "",
      exitCode: null,
      status: "running",
    },
  });
});

test("result.rejected 映射成 BlockStatus 的 rejected，而不是失败或成功", () => {
  const events = runFixture();
  const updates = events.filter(
    (event) => event.type === "blockUpdated" && event.blockId === "toolu_013Tf42Uwp4SvFNusCYUaPkT",
  );
  assert.equal(updates.length, 1);
  assert.deepEqual(updates[0], {
    type: "blockUpdated",
    blockId: "toolu_013Tf42Uwp4SvFNusCYUaPkT",
    patch: { status: "rejected" },
  });
});

test("-p 全程不产生任何审批事件，与 capabilities.approvals=false 一致", () => {
  const events = runFixture();
  assert.equal(
    events.some((event) => event.type === "approvalRequested" || event.type === "approvalSettled"),
    false,
  );
});

test("usage 落到 turnCompleted", () => {
  const events = runFixture();
  assert.deepEqual(events.at(-2), { type: "turnCompleted", inputTokens: 4, outputTokens: 297 });
  assert.deepEqual(events.at(-1), { type: "status", status: "idle" });
});

test("print 驱动的 resolveApproval 必须抛错而不是静默吞掉", async () => {
  const adapter = new CursorAdapter({ drive: "print", emit: () => {} });
  assert.equal(adapter.capabilities.approvals, false);
  await assert.rejects(() => adapter.resolveApproval("whatever", "allow"), /没有审批通道/u);
});
