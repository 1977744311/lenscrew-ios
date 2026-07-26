// git 操作面板的线上契约 —— 手机查看 Mac 端仓库状态/diff 并执行常用 git 操作。
//
// 与会话事件（events.ts）刻意分开：git 是请求-应答语义，结果只回发起请求的
// 那台手机，不进事件流、没有 seq、不参与断档补齐。传输层的对应通道：
//   明文   POST /git                          → { ok, git | error }
//   E2EE   { t: "git", id, data: GitRequest } → { t: "reply", id, ok, git | error }
//
// Swift 侧 Sources/AgentProtocol/Git.swift 是本文件的同构镜像，
// 两边共用 protocol/fixtures/git-panel.json 做往返测试。

/**
 * 手机端发起的 git 请求。root 一律是 Mac 上的绝对路径（通常取会话的
 * workspaceRoot），由 service 校验它确实是一个 git 工作区。
 *
 * paths / branch / message 全部作为 execFile 的参数数组传递，没有 shell
 * 展开；service 另外拒绝以 "-" 开头的 paths 与 branch，防止被解析成 flag。
 */
export type GitRequest =
  | { op: "status"; root: string }
  /** path 为 null 看整仓 diff；staged 区分暂存区与工作区 */
  | { op: "diff"; root: string; path: string | null; staged: boolean }
  | { op: "log"; root: string; limit: number }
  | { op: "branches"; root: string }
  /** paths 为空数组表示全部（git add -A / git reset） */
  | { op: "stage"; root: string; paths: string[] }
  | { op: "unstage"; root: string; paths: string[] }
  /**
   * 丢弃工作区改动：tracked 文件 restore，untracked 文件删除。
   * 破坏性操作，paths 必须显式非空——"全部丢弃"也要由客户端逐个列出，
   * 不给一个能一键清空工作区的快捷方式。
   */
  | { op: "discard"; root: string; paths: string[] }
  | { op: "commit"; root: string; message: string }
  | { op: "push"; root: string }
  | { op: "pull"; root: string }
  /** create 为 true 时等价 git switch -c */
  | { op: "checkout"; root: string; branch: string; create: boolean }
  | { op: "stash"; root: string }
  | { op: "stashPop"; root: string };

/** porcelain 状态字母：M/A/D/R/C/T/U，untracked 恒为 "?" */
export interface GitFileChange {
  path: string;
  code: string;
  /** rename/copy 的旧路径；其余为 null */
  oldPath: string | null;
  /**
   * 增删行数（numstat）。AI 一轮改动动辄几十个文件，列表上没有体量
   * 用户就不知道该先看哪个。二进制、untracked、冲突文件拿不到——
   * 必须是 null，填 0 是在撒谎（与会话流水 FileChangeSummary 同一原则）。
   */
  added: number | null;
  removed: number | null;
}

export interface GitStatusSummary {
  /** 当前分支名；detached HEAD 时为 null */
  branch: string | null;
  /** upstream 短名（origin/main）；未设 upstream 为 null */
  upstream: string | null;
  /** 相对 upstream 的领先/落后；无 upstream 时为 null——填 0 是在撒谎 */
  ahead: number | null;
  behind: number | null;
  staged: GitFileChange[];
  /** 工作区改动，含 untracked（code "?"）与冲突（code "U"） */
  unstaged: GitFileChange[];
  stashCount: number;
}

export interface GitLogEntry {
  sha: string;
  subject: string;
  author: string;
  timeMs: number;
}

/**
 * git 请求的应答。查询各有专属载荷；写操作统一 done + 人读输出。
 * 失败不在这里表达——service 直接抛错，由传输层打包成 { ok: false, error }，
 * git 的 stderr 就是给用户看的错误信息。
 */
export type GitOutcome =
  | { kind: "status"; status: GitStatusSummary }
  /** 超过上限的 diff 会被截断，truncated 告知客户端"还有更多" */
  | { kind: "diff"; text: string; truncated: boolean }
  | { kind: "log"; entries: GitLogEntry[] }
  | { kind: "branches"; current: string | null; local: string[] }
  | { kind: "done"; detail: string };
