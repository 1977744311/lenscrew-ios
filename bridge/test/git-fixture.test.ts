import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import type {
  GitFileChange,
  GitLogEntry,
  GitOutcome,
  GitRequest,
  GitStatusSummary,
} from "../src/protocol/git.ts";

/**
 * git 面板契约测试的 TypeScript 半边，与 contract-fixture.test.ts 同一套路：
 * protocol/fixtures/git-panel.json 是 TS 与 Swift 共用的黄金样本，
 * 重建函数逐字段列出每个变体（编译期护栏），fixture 过一遍重建再深比较（运行期护栏）。
 * Swift 侧在 Tests/AgentProtocolTests/GitFixtureTests.swift 断言同一份文件。
 */

const FIXTURE_PATH = join(
  import.meta.dirname,
  "..",
  "..",
  "protocol",
  "fixtures",
  "git-panel.json",
);

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8")) as {
  requests: GitRequest[];
  outcomes: GitOutcome[];
};

function rebuildRequest(request: GitRequest): GitRequest {
  switch (request.op) {
    case "status":
      return { op: "status", root: request.root };
    case "diff":
      return { op: "diff", root: request.root, path: request.path, staged: request.staged };
    case "log":
      return { op: "log", root: request.root, limit: request.limit };
    case "branches":
      return { op: "branches", root: request.root };
    case "stage":
      return { op: "stage", root: request.root, paths: [...request.paths] };
    case "unstage":
      return { op: "unstage", root: request.root, paths: [...request.paths] };
    case "discard":
      return { op: "discard", root: request.root, paths: [...request.paths] };
    case "commit":
      return { op: "commit", root: request.root, message: request.message };
    case "push":
      return { op: "push", root: request.root };
    case "pull":
      return { op: "pull", root: request.root };
    case "checkout":
      return {
        op: "checkout",
        root: request.root,
        branch: request.branch,
        create: request.create,
      };
    case "stash":
      return { op: "stash", root: request.root };
    case "stashPop":
      return { op: "stashPop", root: request.root };
  }
}

function rebuildFileChange(value: GitFileChange): GitFileChange {
  return { path: value.path, code: value.code, oldPath: value.oldPath };
}

function rebuildStatus(value: GitStatusSummary): GitStatusSummary {
  return {
    branch: value.branch,
    upstream: value.upstream,
    ahead: value.ahead,
    behind: value.behind,
    staged: value.staged.map(rebuildFileChange),
    unstaged: value.unstaged.map(rebuildFileChange),
    stashCount: value.stashCount,
  };
}

function rebuildLogEntry(value: GitLogEntry): GitLogEntry {
  return { sha: value.sha, subject: value.subject, author: value.author, timeMs: value.timeMs };
}

function rebuildOutcome(outcome: GitOutcome): GitOutcome {
  switch (outcome.kind) {
    case "status":
      return { kind: "status", status: rebuildStatus(outcome.status) };
    case "diff":
      return { kind: "diff", text: outcome.text, truncated: outcome.truncated };
    case "log":
      return { kind: "log", entries: outcome.entries.map(rebuildLogEntry) };
    case "branches":
      return { kind: "branches", current: outcome.current, local: [...outcome.local] };
    case "done":
      return { kind: "done", detail: outcome.detail };
  }
}

test("git fixture 每条请求的字段集与契约完全一致", () => {
  assert.ok(fixture.requests.length > 0);
  for (const request of fixture.requests) {
    assert.deepStrictEqual(
      rebuildRequest(request),
      request,
      `请求 ${request.op} 的字段集与契约不一致`,
    );
  }
});

test("git fixture 每条应答的字段集与契约完全一致", () => {
  assert.ok(fixture.outcomes.length > 0);
  for (const outcome of fixture.outcomes) {
    assert.deepStrictEqual(
      rebuildOutcome(outcome),
      outcome,
      `应答 ${outcome.kind} 的字段集与契约不一致`,
    );
  }
});

/** 与 Swift 侧同名断言成对存在：任一侧发现覆盖缺口，两边都该补 */
test("git fixture 覆盖全部十三种请求", () => {
  const ops = new Set(fixture.requests.map((request) => request.op));
  assert.deepStrictEqual(
    [...ops].sort(),
    [
      "branches",
      "checkout",
      "commit",
      "diff",
      "discard",
      "log",
      "pull",
      "push",
      "stage",
      "stash",
      "stashPop",
      "status",
      "unstage",
    ],
  );
});

test("git fixture 覆盖全部五种应答", () => {
  const kinds = new Set(fixture.outcomes.map((outcome) => outcome.kind));
  assert.deepStrictEqual([...kinds].sort(), ["branches", "diff", "done", "log", "status"]);
});

test("git fixture 覆盖可空字段的两种形态", () => {
  const statuses = fixture.outcomes.filter((outcome) => outcome.kind === "status");
  assert.ok(statuses.some((outcome) => outcome.status.branch === null));
  assert.ok(statuses.some((outcome) => outcome.status.branch !== null));
  assert.ok(statuses.some((outcome) => outcome.status.ahead === null));
  assert.ok(statuses.some((outcome) => outcome.status.ahead !== null));

  const changes = statuses.flatMap((outcome) => [
    ...outcome.status.staged,
    ...outcome.status.unstaged,
  ]);
  assert.ok(changes.some((change) => change.oldPath === null));
  assert.ok(changes.some((change) => change.oldPath !== null));
  assert.ok(changes.some((change) => change.code === "?"));

  const branches = fixture.outcomes.filter((outcome) => outcome.kind === "branches");
  assert.ok(branches.some((outcome) => outcome.current === null));
  assert.ok(branches.some((outcome) => outcome.current !== null));
});
