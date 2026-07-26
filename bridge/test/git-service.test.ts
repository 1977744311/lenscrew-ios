import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import { runGitRequest } from "../src/git/service.ts";

/**
 * 对着真 git 仓库测，不 mock：service 的价值全在与 git 实际行为的对齐上
 * （porcelain 解析、rename 记录、无 HEAD 的边界），mock 只能验证自说自话。
 * push/pull 用本地 bare 仓库当 remote，不碰网络。
 */

const execFileAsync = promisify(execFile);

const cleanups: string[] = [];
test.after(async () => {
  for (const dir of cleanups) await rm(dir, { recursive: true, force: true });
});

async function sh(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", args, { cwd });
  return stdout;
}

async function makeDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "lenscrew-git-"));
  cleanups.push(dir);
  return dir;
}

/** 干净的独立仓库：本地身份、不签名、主分支恒为 main，不受全局配置影响 */
async function makeRepo(): Promise<string> {
  const dir = await makeDir();
  await sh(dir, "init", "-b", "main");
  await sh(dir, "config", "user.name", "Tester");
  await sh(dir, "config", "user.email", "tester@example.com");
  await sh(dir, "config", "commit.gpgsign", "false");
  return dir;
}

async function makeRepoWithCommit(): Promise<string> {
  const dir = await makeRepo();
  await writeFile(join(dir, "README.md"), "# proj\n");
  await sh(dir, "add", "-A");
  await sh(dir, "commit", "-m", "initial");
  return dir;
}

test("status：staged/unstaged/untracked 与 rename 各归其位", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "staged.txt"), "s\n");
  await sh(repo, "add", "staged.txt");
  await writeFile(join(repo, "README.md"), "# proj changed\n");
  await writeFile(join(repo, "loose.txt"), "l\n");

  const outcome = await runGitRequest({ op: "status", root: repo });
  assert.equal(outcome.kind, "status");
  if (outcome.kind !== "status") return;
  const status = outcome.status;
  assert.equal(status.branch, "main");
  assert.equal(status.upstream, null);
  assert.equal(status.ahead, null);
  assert.equal(status.behind, null);
  assert.deepEqual(status.staged, [{ path: "staged.txt", code: "A", oldPath: null }]);
  assert.deepEqual(
    status.unstaged.map((change) => [change.path, change.code]),
    [
      ["README.md", "M"],
      ["loose.txt", "?"],
    ],
  );
});

test("status：staged rename 带旧路径", async () => {
  const repo = await makeRepoWithCommit();
  await sh(repo, "mv", "README.md", "RENAMED.md");

  const outcome = await runGitRequest({ op: "status", root: repo });
  assert.equal(outcome.kind, "status");
  if (outcome.kind !== "status") return;
  assert.deepEqual(outcome.status.staged, [
    { path: "RENAMED.md", code: "R", oldPath: "README.md" },
  ]);
});

test("status：含空格与中文的路径不会被转义搞坏", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "带 空格 的文件.txt"), "x\n");

  const outcome = await runGitRequest({ op: "status", root: repo });
  assert.equal(outcome.kind, "status");
  if (outcome.kind !== "status") return;
  assert.deepEqual(outcome.status.unstaged, [
    { path: "带 空格 的文件.txt", code: "?", oldPath: null },
  ]);
});

test("status：stash 数量与 detached HEAD", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "README.md"), "stash me\n");
  await sh(repo, "stash", "push");
  const sha = (await sh(repo, "rev-parse", "HEAD")).trim();
  await sh(repo, "checkout", "--detach", sha);

  const outcome = await runGitRequest({ op: "status", root: repo });
  assert.equal(outcome.kind, "status");
  if (outcome.kind !== "status") return;
  assert.equal(outcome.status.branch, null);
  assert.equal(outcome.status.stashCount, 1);
});

test("diff：工作区、暂存区与 untracked 文件三条路都出内容", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "README.md"), "# proj changed\n");

  const worktree = await runGitRequest({
    op: "diff",
    root: repo,
    path: null,
    staged: false,
  });
  assert.equal(worktree.kind, "diff");
  if (worktree.kind !== "diff") return;
  assert.match(worktree.text, /\+# proj changed/);
  assert.equal(worktree.truncated, false);

  await sh(repo, "add", "README.md");
  const staged = await runGitRequest({
    op: "diff",
    root: repo,
    path: "README.md",
    staged: true,
  });
  assert.equal(staged.kind, "diff");
  if (staged.kind !== "diff") return;
  assert.match(staged.text, /\+# proj changed/);

  // untracked 文件不在 git diff 视野里，走 --no-index 给出"全是新增"的 diff
  await writeFile(join(repo, "fresh.txt"), "brand new\n");
  const untracked = await runGitRequest({
    op: "diff",
    root: repo,
    path: "fresh.txt",
    staged: false,
  });
  assert.equal(untracked.kind, "diff");
  if (untracked.kind !== "diff") return;
  assert.match(untracked.text, /\+brand new/);
});

test("diff：超限截断并打标", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "big.txt"), `${"x".repeat(400 * 1024)}\n`);
  await sh(repo, "add", "big.txt");

  const outcome = await runGitRequest({ op: "diff", root: repo, path: null, staged: true });
  assert.equal(outcome.kind, "diff");
  if (outcome.kind !== "diff") return;
  assert.equal(outcome.truncated, true);
  assert.equal(outcome.text.length, 256 * 1024);
});

test("log：按新到旧排列；无 HEAD 的空仓库返回空表而不是报错", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "second.txt"), "2\n");
  await sh(repo, "add", "-A");
  await sh(repo, "commit", "-m", "second commit");

  const outcome = await runGitRequest({ op: "log", root: repo, limit: 10 });
  assert.equal(outcome.kind, "log");
  if (outcome.kind !== "log") return;
  assert.equal(outcome.entries.length, 2);
  assert.equal(outcome.entries[0]?.subject, "second commit");
  assert.equal(outcome.entries[1]?.subject, "initial");
  assert.equal(outcome.entries[0]?.author, "Tester");
  assert.ok((outcome.entries[0]?.timeMs ?? 0) > 1_600_000_000_000);
  assert.match(outcome.entries[0]?.sha ?? "", /^[0-9a-f]{40}$/);

  const empty = await runGitRequest({ op: "log", root: await makeRepo(), limit: 10 });
  assert.equal(empty.kind, "log");
  if (empty.kind !== "log") return;
  assert.deepEqual(empty.entries, []);
});

test("branches：列出本地分支并标出当前", async () => {
  const repo = await makeRepoWithCommit();
  await sh(repo, "branch", "feature/x");

  const outcome = await runGitRequest({ op: "branches", root: repo });
  assert.deepEqual(outcome, { kind: "branches", current: "main", local: ["feature/x", "main"] });
});

test("stage/unstage：指定路径与全部两种形态", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "a.txt"), "a\n");
  await writeFile(join(repo, "b.txt"), "b\n");

  await runGitRequest({ op: "stage", root: repo, paths: ["a.txt"] });
  let status = await sh(repo, "status", "--porcelain");
  assert.match(status, /^A {2}a\.txt$/m);
  assert.match(status, /^\?\? b\.txt$/m);

  await runGitRequest({ op: "stage", root: repo, paths: [] });
  status = await sh(repo, "status", "--porcelain");
  assert.match(status, /^A {2}b\.txt$/m);

  await runGitRequest({ op: "unstage", root: repo, paths: ["a.txt"] });
  status = await sh(repo, "status", "--porcelain");
  assert.match(status, /^\?\? a\.txt$/m);
});

test("unstage：首个 commit 之前没有 HEAD 也能把文件摘下索引", async () => {
  const repo = await makeRepo();
  await writeFile(join(repo, "early.txt"), "e\n");
  await sh(repo, "add", "early.txt");

  await runGitRequest({ op: "unstage", root: repo, paths: ["early.txt"] });
  const status = await sh(repo, "status", "--porcelain");
  assert.match(status, /^\?\? early\.txt$/m);
});

test("discard：tracked 恢复原样，untracked 连文件带目录删掉", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "README.md"), "dirty\n");
  await writeFile(join(repo, "loose.txt"), "l\n");
  await mkdir(join(repo, "junk"));
  await writeFile(join(repo, "junk", "deep.txt"), "d\n");

  await runGitRequest({
    op: "discard",
    root: repo,
    paths: ["README.md", "loose.txt", "junk/"],
  });
  const status = await sh(repo, "status", "--porcelain");
  assert.equal(status, "");
  assert.equal(existsSync(join(repo, "loose.txt")), false);
  assert.equal(existsSync(join(repo, "junk")), false);

  await assert.rejects(
    runGitRequest({ op: "discard", root: repo, paths: [] }),
    /显式列出/,
  );
});

test("commit：提交暂存内容；空信息被拒绝", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "c.txt"), "c\n");
  await sh(repo, "add", "c.txt");

  const outcome = await runGitRequest({ op: "commit", root: repo, message: "add c" });
  assert.equal(outcome.kind, "done");
  const subject = (await sh(repo, "log", "-1", "--format=%s")).trim();
  assert.equal(subject, "add c");

  await assert.rejects(
    runGitRequest({ op: "commit", root: repo, message: "  " }),
    /提交信息不能为空/,
  );
});

test("push/pull：对本地 bare remote，首推自动补 upstream，pull 只快进", async () => {
  const bare = await makeDir();
  await sh(bare, "init", "--bare", "-b", "main");

  const writer = await makeRepoWithCommit();
  await sh(writer, "remote", "add", "origin", bare);
  // 尚无 upstream：push 应当自动 -u origin HEAD 而不是让用户回 Mac 补敲
  await runGitRequest({ op: "push", root: writer });
  const upstream = (await sh(writer, "rev-parse", "--abbrev-ref", "@{upstream}")).trim();
  assert.equal(upstream, "origin/main");

  const readerParent = await makeDir();
  const reader = join(readerParent, "clone");
  await execFileAsync("git", ["clone", bare, reader]);
  await sh(reader, "config", "user.name", "Reader");
  await sh(reader, "config", "user.email", "reader@example.com");
  await sh(reader, "config", "commit.gpgsign", "false");

  await writeFile(join(writer, "more.txt"), "m\n");
  await sh(writer, "add", "-A");
  await sh(writer, "commit", "-m", "more");
  await runGitRequest({ op: "push", root: writer });

  const pulled = await runGitRequest({ op: "pull", root: reader });
  assert.equal(pulled.kind, "done");
  assert.equal(existsSync(join(reader, "more.txt")), true);

  // 本地与远端分叉时 --ff-only 拒绝制造合并/冲突，让用户回 Mac 处理
  await writeFile(join(reader, "local.txt"), "l\n");
  await sh(reader, "add", "-A");
  await sh(reader, "commit", "-m", "local");
  await writeFile(join(writer, "remote.txt"), "r\n");
  await sh(writer, "add", "-A");
  await sh(writer, "commit", "-m", "remote");
  await runGitRequest({ op: "push", root: writer });
  await assert.rejects(runGitRequest({ op: "pull", root: reader }));
});

test("checkout：切换与新建分支", async () => {
  const repo = await makeRepoWithCommit();
  await runGitRequest({ op: "checkout", root: repo, branch: "feature/y", create: true });
  assert.equal((await sh(repo, "branch", "--show-current")).trim(), "feature/y");

  await runGitRequest({ op: "checkout", root: repo, branch: "main", create: false });
  assert.equal((await sh(repo, "branch", "--show-current")).trim(), "main");
});

test("stash/stashPop：往返后改动回到工作区", async () => {
  const repo = await makeRepoWithCommit();
  await writeFile(join(repo, "README.md"), "stashed change\n");

  await runGitRequest({ op: "stash", root: repo });
  assert.equal((await sh(repo, "status", "--porcelain")).trim(), "");

  await runGitRequest({ op: "stashPop", root: repo });
  assert.match(await sh(repo, "status", "--porcelain"), /^ M README\.md$/m);
});

test("护栏：非 git 目录、相对路径、flag 注入形态的输入一律拒绝", async () => {
  const plain = await makeDir();
  await assert.rejects(
    runGitRequest({ op: "status", root: plain }),
    /不是 git 工作区/,
  );
  await assert.rejects(
    runGitRequest({ op: "status", root: "relative/path" }),
    /绝对路径/,
  );
  await assert.rejects(
    runGitRequest({ op: "status", root: join(plain, "missing") }),
    /目录不存在/,
  );

  const repo = await makeRepoWithCommit();
  await assert.rejects(
    runGitRequest({ op: "stage", root: repo, paths: ["--force"] }),
    /非法路径/,
  );
  await assert.rejects(
    runGitRequest({ op: "checkout", root: repo, branch: "-b evil", create: false }),
    /非法分支名/,
  );
});

test("失败透传 git 的人话错误而不是吞掉", async () => {
  const repo = await makeRepoWithCommit();
  await assert.rejects(
    runGitRequest({ op: "checkout", root: repo, branch: "no-such-branch", create: false }),
    (error: Error) => error.message.includes("no-such-branch"),
  );
});
