// git 操作面板的执行侧：把 GitRequest 翻译成对 Mac 本机 git 的调用。
//
// 安全边界与 agent 一致——已配对的手机本来就能驱动 agent 跑任意命令，
// 这里不做路径白名单；要防的是意外而不是恶意：
//   - 一切参数走 execFile 数组，没有 shell 展开
//   - paths/branch 拒绝以 "-" 开头，防止被 git 解析成 flag
//   - push/pull 关掉终端提问（GIT_TERMINAL_PROMPT=0），卡住不如立刻失败
//   - pull 恒为 --ff-only：手机是控制面，合并冲突不该在手机上发生
//
// 无状态纯函数：每个请求独立 spawn，一次性短命进程（参考 quotaProbe 的模式）。
// 并发写操作靠 git 自身的 index.lock 兜底，失败原样透传。

import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import { isAbsolute } from "node:path";

import type {
  GitFileChange,
  GitLogEntry,
  GitOutcome,
  GitRequest,
  GitStatusSummary,
} from "../protocol/git.ts";

/** 传输层持有的执行器签名，测试用 stub 顶替真 git */
export type GitRunner = (request: GitRequest) => Promise<GitOutcome>;

const LOCAL_TIMEOUT_MS = 15_000;
/** push/pull 走网络，大仓库慢网要宽容得多 */
const NETWORK_TIMEOUT_MS = 120_000;
/** commit 会触发 pre-commit hook（lint、测试），比普通本地操作慢 */
const COMMIT_TIMEOUT_MS = 60_000;
/** 手机上看不完的 diff 没必要整个传过去 */
const DIFF_LIMIT_CHARS = 256 * 1024;
const MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const LOG_LIMIT_MAX = 200;

export async function runGitRequest(request: GitRequest): Promise<GitOutcome> {
  await assertGitWorkTree(request.root);
  const root = request.root;

  switch (request.op) {
    case "status":
      return { kind: "status", status: await readStatus(root) };
    case "diff":
      return readDiff(root, request.path, request.staged);
    case "log":
      return { kind: "log", entries: await readLog(root, request.limit) };
    case "branches":
      return readBranches(root);
    case "stage":
      return runStage(root, request.paths);
    case "unstage":
      return runUnstage(root, request.paths);
    case "discard":
      return runDiscard(root, request.paths);
    case "commit":
      return runCommit(root, request.message);
    case "push":
      return runPush(root);
    case "pull":
      return done(await git(root, ["pull", "--ff-only"], NETWORK_TIMEOUT_MS));
    case "checkout": {
      assertSafeBranch(request.branch);
      const args = request.create ? ["switch", "-c", request.branch] : ["switch", request.branch];
      return done(await git(root, args));
    }
    case "stash":
      return done(await git(root, ["stash", "push"]));
    case "stashPop":
      return done(await git(root, ["stash", "pop"]));
  }
}

// MARK: - 查询

async function readStatus(root: string): Promise<GitStatusSummary> {
  const [status, stash, stagedStat, worktreeStat] = await Promise.all([
    git(root, ["status", "--porcelain=v2", "--branch", "-z"]),
    git(root, ["stash", "list", "--format=%gd"]),
    git(root, ["diff", "--cached", "--numstat", "-z"]),
    git(root, ["diff", "--numstat", "-z"]),
  ]);
  const summary = parsePorcelainV2(status.stdout);
  summary.stashCount = stash.stdout.split("\n").filter((line) => line !== "").length;
  // AI 一轮改动动辄几十个文件，列表上必须能看出体量，用户才知道先看哪个
  applyNumstat(summary.staged, parseNumstat(stagedStat.stdout));
  applyNumstat(summary.unstaged, parseNumstat(worktreeStat.stdout));
  return summary;
}

interface LineStat {
  added: number | null;
  removed: number | null;
}

/**
 * numstat -z：`added\tremoved\tpath\0`；rename 的路径字段为空，
 * 后跟 NUL 分隔的旧、新两个路径；二进制的行数是 "-"。
 */
function parseNumstat(stdout: string): Map<string, LineStat> {
  const stats = new Map<string, LineStat>();
  const tokens = stdout.split("\0");
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index] ?? "";
    if (token === "") continue;
    const fields = token.split("\t");
    if (fields.length < 3) continue;
    const added = fields[0] === "-" ? null : Number(fields[0]);
    const removed = fields[1] === "-" ? null : Number(fields[1]);
    let path = fields.slice(2).join("\t");
    if (path === "") {
      // rename 记录：跳过旧路径，按新路径记账（与 porcelain 的 path 对齐）
      index += 2;
      path = tokens[index] ?? "";
    }
    if (path !== "") stats.set(path, { added, removed });
  }
  return stats;
}

/** untracked 与冲突文件不在 numstat 里，保持 null——填 0 是在撒谎 */
function applyNumstat(changes: GitFileChange[], stats: Map<string, LineStat>): void {
  for (const change of changes) {
    const stat = stats.get(change.path);
    if (stat === undefined) continue;
    change.added = stat.added;
    change.removed = stat.removed;
  }
}

/**
 * porcelain v2 -z：记录以 NUL 分隔，"2"（rename/copy）记录的旧路径占下一个字段。
 * 用 -z 是因为普通模式会对含空格/非 ASCII 的路径加引号转义，解析会错。
 */
function parsePorcelainV2(stdout: string): GitStatusSummary {
  const summary: GitStatusSummary = {
    branch: null,
    upstream: null,
    ahead: null,
    behind: null,
    staged: [],
    unstaged: [],
    stashCount: 0,
  };

  const tokens = stdout.split("\0");
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index] ?? "";
    if (token === "") continue;

    if (token.startsWith("# branch.head ")) {
      const head = token.slice("# branch.head ".length);
      summary.branch = head === "(detached)" ? null : head;
      continue;
    }
    if (token.startsWith("# branch.upstream ")) {
      summary.upstream = token.slice("# branch.upstream ".length);
      continue;
    }
    const ab = /^# branch\.ab \+(\d+) -(\d+)$/.exec(token);
    if (ab !== null) {
      summary.ahead = Number(ab[1]);
      summary.behind = Number(ab[2]);
      continue;
    }
    if (token.startsWith("# ")) continue;

    const type = token[0];
    if (type === "?") {
      summary.unstaged.push(fileChange(token.slice(2), "?", null));
      continue;
    }
    if (type !== "1" && type !== "2" && type !== "u") continue;

    // 头部字段数：1 → XY sub mH mI mW hH hI；2 → 再加 Xscore；u → XY sub m1 m2 m3 mW h1 h2 h3
    const headFields = type === "1" ? 8 : type === "2" ? 9 : 10;
    const parts = token.split(" ");
    const xy = parts[1] ?? "..";
    const path = parts.slice(headFields).join(" ");
    let oldPath: string | null = null;
    if (type === "2") {
      index += 1;
      oldPath = tokens[index] ?? null;
    }

    if (type === "u") {
      summary.unstaged.push(fileChange(path, "U", null));
      continue;
    }
    const x = xy[0] ?? ".";
    const y = xy[1] ?? ".";
    if (x !== ".") {
      summary.staged.push(fileChange(path, x, oldPath));
    }
    if (y !== ".") {
      summary.unstaged.push(fileChange(path, y, oldPath));
    }
  }
  return summary;
}

function fileChange(path: string, code: string, oldPath: string | null): GitFileChange {
  return {
    path,
    code,
    oldPath: code === "R" || code === "C" ? oldPath : null,
    added: null,
    removed: null,
  };
}

async function readDiff(
  root: string,
  path: string | null,
  staged: boolean,
): Promise<GitOutcome> {
  if (path !== null) assertSafePaths([path]);
  const args = staged ? ["diff", "--cached"] : ["diff"];
  if (path !== null) args.push("--", path);
  const { stdout } = await git(root, args);
  if (stdout !== "" || path === null || staged) {
    return { kind: "diff", ...clipDiff(stdout) };
  }
  // 工作区单文件 diff 为空：untracked 文件不在 git diff 的视野里，
  // 用 --no-index 对 /dev/null 给出"整个文件都是新增"的 diff（有差异时退出码为 1）
  const tracked = await git(root, ["ls-files", "--error-unmatch", "--", path]).then(
    () => true,
    () => false,
  );
  if (tracked) return { kind: "diff", text: "", truncated: false };
  const noIndex = await git(
    root,
    ["diff", "--no-index", "--", "/dev/null", path],
    LOCAL_TIMEOUT_MS,
    [0, 1],
  );
  return { kind: "diff", ...clipDiff(noIndex.stdout) };
}

function clipDiff(text: string): { text: string; truncated: boolean } {
  if (text.length <= DIFF_LIMIT_CHARS) return { text, truncated: false };
  // 截断落在行边界上：diff 是按行着色/对齐的，半行会被客户端渲染错
  const slice = text.slice(0, DIFF_LIMIT_CHARS);
  const lastNewline = slice.lastIndexOf("\n");
  return {
    text: lastNewline > 0 ? slice.slice(0, lastNewline + 1) : slice,
    truncated: true,
  };
}

const FIELD_SEP = "\x1f";
const RECORD_SEP = "\x1e";

async function readLog(root: string, limit: number): Promise<GitLogEntry[]> {
  if (!(await hasHead(root))) return [];
  const count = Math.max(1, Math.min(Math.trunc(limit), LOG_LIMIT_MAX));
  const format = `%H${FIELD_SEP}%an${FIELD_SEP}%ct${FIELD_SEP}%s${RECORD_SEP}`;
  const { stdout } = await git(root, ["log", `--format=${format}`, "-n", String(count)]);
  const entries: GitLogEntry[] = [];
  for (const record of stdout.split(RECORD_SEP)) {
    const fields = record.replace(/^\n/, "").split(FIELD_SEP);
    if (fields.length < 4) continue;
    entries.push({
      sha: fields[0] ?? "",
      author: fields[1] ?? "",
      timeMs: Number(fields[2]) * 1000,
      subject: fields[3] ?? "",
    });
  }
  return entries;
}

async function readBranches(root: string): Promise<GitOutcome> {
  const [refs, current] = await Promise.all([
    git(root, ["for-each-ref", "refs/heads/", "--format=%(refname:short)"]),
    git(root, ["branch", "--show-current"]),
  ]);
  const local = refs.stdout.split("\n").filter((line) => line !== "");
  const head = current.stdout.trim();
  return { kind: "branches", current: head === "" ? null : head, local };
}

// MARK: - 写操作

async function runStage(root: string, paths: string[]): Promise<GitOutcome> {
  assertSafePaths(paths);
  const args = paths.length === 0 ? ["add", "-A"] : ["add", "--", ...paths];
  return done(await git(root, args));
}

async function runUnstage(root: string, paths: string[]): Promise<GitOutcome> {
  assertSafePaths(paths);
  if (await hasHead(root)) {
    return done(await git(root, ["reset", "--", ...paths]));
  }
  // 首个 commit 之前没有 HEAD 可 reset，此时的 staged 全是新加文件，从索引摘下即可
  const targets = paths.length === 0 ? ["."] : paths;
  return done(await git(root, ["rm", "--cached", "-r", "--", ...targets]));
}

/**
 * 丢弃工作区改动。tracked 与 untracked 的"丢弃"是两个不同的 git 动作，
 * 分类以本仓库当前 status 为准（bridge 权威），客户端只传路径不传语义。
 */
async function runDiscard(root: string, paths: string[]): Promise<GitOutcome> {
  assertSafePaths(paths);
  if (paths.length === 0) throw new Error("discard 必须显式列出要丢弃的路径");

  const status = await readStatus(root);
  const untracked = new Set(
    status.unstaged.filter((change) => change.code === "?").map((change) => change.path),
  );
  const restoreTargets = paths.filter((path) => !untracked.has(path));
  const cleanTargets = paths.filter((path) => untracked.has(path));

  const outputs: string[] = [];
  if (restoreTargets.length > 0) {
    outputs.push(detail(await git(root, ["restore", "--", ...restoreTargets])));
  }
  if (cleanTargets.length > 0) {
    // -d：untracked 的整个目录也能被 status 列成单条 "?" 记录
    outputs.push(detail(await git(root, ["clean", "-fd", "--", ...cleanTargets])));
  }
  return { kind: "done", detail: outputs.filter((text) => text !== "").join("\n") };
}

async function runCommit(root: string, message: string): Promise<GitOutcome> {
  if (message.trim() === "") throw new Error("提交信息不能为空");
  return done(await git(root, ["commit", "-m", message], COMMIT_TIMEOUT_MS));
}

async function runPush(root: string): Promise<GitOutcome> {
  const hasUpstream = await git(root, [
    "rev-parse",
    "--abbrev-ref",
    "--symbolic-full-name",
    "@{upstream}",
  ]).then(
    () => true,
    () => false,
  );
  if (hasUpstream) {
    return done(await git(root, ["push"], NETWORK_TIMEOUT_MS));
  }
  // 新分支还没有 upstream：手机上没法补敲 --set-upstream，给出常用默认
  return done(await git(root, ["push", "-u", "origin", "HEAD"], NETWORK_TIMEOUT_MS));
}

// MARK: - 基础设施

async function assertGitWorkTree(root: string): Promise<void> {
  if (!isAbsolute(root)) throw new Error(`root 必须是绝对路径：${root}`);
  const stats = await stat(root).catch(() => null);
  if (stats === null || !stats.isDirectory()) throw new Error(`目录不存在：${root}`);
  const inside = await git(root, ["rev-parse", "--is-inside-work-tree"]).then(
    (result) => result.stdout.trim() === "true",
    () => false,
  );
  if (!inside) throw new Error(`不是 git 工作区：${root}`);
}

function assertSafePaths(paths: string[]): void {
  for (const path of paths) {
    if (path === "" || path.startsWith("-")) throw new Error(`非法路径：${path}`);
  }
}

function assertSafeBranch(branch: string): void {
  if (branch === "" || branch.startsWith("-") || /[\s\0]/.test(branch)) {
    throw new Error(`非法分支名：${branch}`);
  }
}

async function hasHead(root: string): Promise<boolean> {
  return git(root, ["rev-parse", "--verify", "-q", "HEAD"]).then(
    () => true,
    () => false,
  );
}

function done(result: { stdout: string; stderr: string }): GitOutcome {
  return { kind: "done", detail: detail(result) };
}

/** push/pull 的进度与摘要写在 stderr，成功输出也要一并带给用户 */
function detail(result: { stdout: string; stderr: string }): string {
  return [result.stdout.trim(), result.stderr.trim()].filter((text) => text !== "").join("\n");
}

function git(
  root: string,
  args: string[],
  timeoutMs: number = LOCAL_TIMEOUT_MS,
  okExitCodes: number[] = [0],
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(
      "git",
      args,
      {
        cwd: root,
        timeout: timeoutMs,
        maxBuffer: MAX_BUFFER_BYTES,
        // 手机端没有终端可回答用户名/密码，卡住直到超时不如立刻失败
        env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
      },
      (error, stdout, stderr) => {
        if (error === null) {
          resolve({ stdout, stderr });
          return;
        }
        const exitCode = typeof error.code === "number" ? error.code : null;
        if (exitCode !== null && okExitCodes.includes(exitCode)) {
          resolve({ stdout, stderr });
          return;
        }
        if (error.killed === true) {
          reject(new Error(`git ${args[0]} 超时（${Math.round(timeoutMs / 1000)}s）`));
          return;
        }
        const reason = stderr.trim() !== "" ? stderr.trim() : stdout.trim();
        reject(new Error(reason !== "" ? reason : `git ${args[0]} 失败：${error.message}`));
      },
    );
  });
}
