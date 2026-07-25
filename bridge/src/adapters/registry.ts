import type { AdapterFactory } from "../session/hub.ts";
import { ClaudeAdapter } from "./claude/adapter.ts";
import { CodexAdapter } from "./codex/adapter.ts";
import { CursorAdapter } from "./cursor/adapter.ts";

/**
 * 三个 adapter 的构造形状各不相同（各自按自己运行时的需要收参数），
 * 差异到此为止——SessionHub 只看见 `(kind, sink) => AgentAdapter`。
 */
export const defaultAdapterFactory: AdapterFactory = (kind, sink) => {
  switch (kind) {
    case "codex":
      return new CodexAdapter({ sink });
    case "claude":
      return new ClaudeAdapter(sink);
    case "cursor":
      return new CursorAdapter({ emit: sink });
  }
};
