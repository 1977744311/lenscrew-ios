// 会话持久化：bridge 重启后把上次的会话自动续接回来。
//
// 三个运行时的原生会话本来就落在各自的状态目录里（codex rollout、
// claude session、cursor chat），丢的只是 bridge 内存里的"路由表"——
// 这里把路由表落盘（agent + nativeId + workspaceRoot + 模式），
// 重启时逐条 resume 即可。文件在 ~/.lenscrew 下，0600，与其它状态同级。

import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { AgentKind } from "../protocol/events.ts";

const SESSIONS_FILE = "sessions.json";

export interface PersistedSession {
  agent: AgentKind;
  nativeId: string;
  workspaceRoot: string;
  model: string | null;
  modeId: string | null;
  updatedAtMs: number;
}

export function loadPersistedSessions(dir: string): PersistedSession[] {
  const path = join(dir, SESSIONS_FILE);
  if (!existsSync(path)) return [];
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (record): record is PersistedSession =>
        typeof record === "object" &&
        record !== null &&
        typeof (record as PersistedSession).agent === "string" &&
        typeof (record as PersistedSession).nativeId === "string" &&
        typeof (record as PersistedSession).workspaceRoot === "string",
    );
  } catch {
    // 损坏的持久化不该挡 bridge 启动，代价只是这次不恢复
    return [];
  }
}

export function savePersistedSessions(dir: string, sessions: PersistedSession[]): void {
  const path = join(dir, SESSIONS_FILE);
  writeFileSync(path, `${JSON.stringify(sessions, null, 2)}\n`, { mode: 0o600 });
  // mode 只在新建时生效，覆盖后要重新收紧
  chmodSync(path, 0o600);
}
