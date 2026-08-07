#!/usr/bin/env node
/**
 * Maintainer-only live smoke against real agent CLIs on PATH.
 *
 * NOT part of default `node --test` / PR CI. Missing CLIs are skipped cleanly.
 *
 *   cd bridge && node scripts/agent-smoke.ts
 *   cd bridge && node scripts/agent-smoke.ts --agent codex
 *   cd bridge && node scripts/agent-smoke.ts --timeout-ms 180000
 *
 * Per available agent: detect version → adapter start (handshake + session) →
 * one trivial prompt → wait for turnCompleted → teardown.
 * Failures name agent + version + step.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ClaudeAdapter } from "../src/adapters/claude/adapter.ts";
import { CodexAdapter } from "../src/adapters/codex/adapter.ts";
import { CursorAdapter } from "../src/adapters/cursor/adapter.ts";
import type {
  AdapterEvent,
  AdapterEventSink,
  AdapterStartOptions,
  AgentAdapter,
} from "../src/adapters/types.ts";
import type { AgentKind } from "../src/protocol/events.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../..");
const VERSIONS_PATH = join(REPO_ROOT, "protocol/fixtures/agent-versions.json");
const TRIVIAL_PROMPT =
  "Reply with exactly the single word pong and nothing else. Do not use tools.";

interface PinnedAgent {
  command: string;
  version: string;
  versionCommand: string[];
}

interface AgentVersionsFile {
  pinned: Record<"codex" | "claude" | "cursor", PinnedAgent>;
}

type SmokeStep =
  | "detect"
  | "initialize"
  | "prompt"
  | "turnCompleted"
  | "teardown";

class SmokeFailure extends Error {
  readonly agent: AgentKind;
  readonly version: string;
  readonly step: SmokeStep;

  constructor(agent: AgentKind, version: string, step: SmokeStep, message: string) {
    super(`[${agent} ${version}] step=${step}: ${message}`);
    this.name = "SmokeFailure";
    this.agent = agent;
    this.version = version;
    this.step = step;
  }
}

interface AgentSpec {
  kind: AgentKind;
  pinKey: "codex" | "claude" | "cursor";
  /** Mode that minimizes tool use for a one-line reply */
  modeId: string;
  make: (sink: AdapterEventSink, command: string) => AgentAdapter;
}

const SPECS: AgentSpec[] = [
  {
    kind: "codex",
    pinKey: "codex",
    modeId: "plan",
    make: (sink, command) => new CodexAdapter({ sink, command }),
  },
  {
    kind: "claude",
    pinKey: "claude",
    modeId: "plan",
    make: (sink, command) => new ClaudeAdapter(sink, command),
  },
  {
    kind: "cursor",
    pinKey: "cursor",
    modeId: "ask",
    make: (sink, command) => new CursorAdapter({ emit: sink, binary: command }),
  },
];

function parseArgs(argv: string[]): {
  only: AgentKind | null;
  timeoutMs: number;
} {
  let only: AgentKind | null = null;
  let timeoutMs = 120_000;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "--agent") {
      const value = argv[++i];
      if (value !== "codex" && value !== "claude" && value !== "cursor") {
        throw new Error(`--agent must be codex|claude|cursor, got ${value ?? "(missing)"}`);
      }
      only = value;
    } else if (arg === "--timeout-ms") {
      const value = Number(argv[++i]);
      if (!Number.isFinite(value) || value < 5_000) {
        throw new Error(`--timeout-ms must be >= 5000, got ${argv[i] ?? "(missing)"}`);
      }
      timeoutMs = value;
    } else if (arg === "--help" || arg === "-h") {
      console.log(`Usage: node scripts/agent-smoke.ts [--agent codex|claude|cursor] [--timeout-ms N]`);
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return { only, timeoutMs };
}

function loadPins(): AgentVersionsFile {
  return JSON.parse(readFileSync(VERSIONS_PATH, "utf8")) as AgentVersionsFile;
}

function which(command: string): string | null {
  const result = spawnSync("which", [command], { encoding: "utf8" });
  if (result.status !== 0) return null;
  const path = result.stdout.trim();
  return path.length > 0 ? path : null;
}

function detectVersion(command: string, versionArgs: string[]): string {
  const result = spawnSync(command, versionArgs, {
    encoding: "utf8",
    timeout: 15_000,
  });
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  if (result.status !== 0 && text.length === 0) {
    throw new Error(`version command failed (exit ${result.status})`);
  }
  const firstLine = text.split(/\r?\n/).find((line) => line.trim().length > 0) ?? text;
  return firstLine.trim() || "(unknown)";
}

function denyOptionId(event: Extract<AdapterEvent, { type: "approvalRequested" }>): string | null {
  const options = event.approval.options;
  const byKind = options.find((option) => option.kind === "deny" || option.kind === "abort");
  if (byKind) return byKind.id;
  const byLabel = options.find((option) =>
    /deny|decline|reject|cancel|no/i.test(`${option.id} ${option.label}`),
  );
  return byLabel?.id ?? options[0]?.id ?? null;
}

async function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  onTimeout: () => Error,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(onTimeout()), ms);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

async function smokeOne(
  spec: AgentSpec,
  pin: PinnedAgent,
  timeoutMs: number,
): Promise<"ok" | "skip"> {
  const path = which(pin.command);
  if (path === null) {
    console.log(`SKIP ${spec.kind}: \`${pin.command}\` not on PATH`);
    return "skip";
  }

  let version = "(unknown)";
  try {
    version = detectVersion(pin.command, pin.versionCommand);
  } catch (error) {
    throw new SmokeFailure(
      spec.kind,
      version,
      "detect",
      error instanceof Error ? error.message : String(error),
    );
  }

  const drift =
    version.includes(pin.version) || pin.version.split(".").every((part) => version.includes(part))
      ? ""
      : ` (pinned ${pin.version} — drift; update fixtures/README when intentional)`;
  console.log(`→ ${spec.kind} @ ${version}${drift}`);
  console.log(`  binary: ${path}`);

  const workspace = mkdtempSync(join(tmpdir(), `lenscrew-smoke-${spec.kind}-`));
  const events: AdapterEvent[] = [];
  let turnDone: (() => void) | null = null;
  const turnPromise = new Promise<void>((resolve) => {
    turnDone = resolve;
  });
  let fatal: string | null = null;
  let adapter!: AgentAdapter;

  const sink: AdapterEventSink = (event) => {
    events.push(event);
    if (event.type === "turnCompleted") turnDone?.();
    if (event.type === "error" && event.fatal) {
      fatal = event.message;
      turnDone?.();
    }
    if (event.type === "approvalRequested") {
      const optionId = denyOptionId(event);
      if (optionId !== null) {
        void adapter.resolveApproval(event.approval.id, optionId).catch(() => {});
      }
    }
  };

  adapter = spec.make(sink, pin.command);
  const startOptions: AdapterStartOptions = {
    workspaceRoot: workspace,
    model: null,
    modeId: spec.modeId,
    reasoningEffort: null,
    resumeNativeId: null,
  };

  try {
    try {
      await withTimeout(
        adapter.start(startOptions),
        timeoutMs,
        () =>
          new SmokeFailure(spec.kind, version, "initialize", `timed out after ${timeoutMs}ms`),
      );
    } catch (error) {
      if (error instanceof SmokeFailure) throw error;
      throw new SmokeFailure(
        spec.kind,
        version,
        "initialize",
        error instanceof Error ? error.message : String(error),
      );
    }

    try {
      await withTimeout(
        adapter.sendMessage(TRIVIAL_PROMPT),
        timeoutMs,
        () => new SmokeFailure(spec.kind, version, "prompt", `timed out after ${timeoutMs}ms`),
      );
    } catch (error) {
      if (error instanceof SmokeFailure) throw error;
      throw new SmokeFailure(
        spec.kind,
        version,
        "prompt",
        error instanceof Error ? error.message : String(error),
      );
    }

    try {
      await withTimeout(
        turnPromise,
        timeoutMs,
        () =>
          new SmokeFailure(
            spec.kind,
            version,
            "turnCompleted",
            `no turnCompleted within ${timeoutMs}ms`,
          ),
      );
    } catch (error) {
      if (error instanceof SmokeFailure) throw error;
      throw new SmokeFailure(
        spec.kind,
        version,
        "turnCompleted",
        error instanceof Error ? error.message : String(error),
      );
    }

    if (fatal !== null) {
      throw new SmokeFailure(spec.kind, version, "turnCompleted", fatal);
    }
    if (!events.some((event) => event.type === "turnCompleted")) {
      throw new SmokeFailure(
        spec.kind,
        version,
        "turnCompleted",
        "resolved without turnCompleted event",
      );
    }

    console.log(`  OK ${spec.kind} (${events.filter((e) => e.type === "turnCompleted").length} turn)`);
    return "ok";
  } finally {
    try {
      await withTimeout(
        adapter.close(),
        15_000,
        () => new SmokeFailure(spec.kind, version, "teardown", "close timed out"),
      );
    } catch (error) {
      console.warn(
        `  warn teardown: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    rmSync(workspace, { recursive: true, force: true });
  }
}

async function main(): Promise<void> {
  const { only, timeoutMs } = parseArgs(process.argv.slice(2));
  const pins = loadPins();

  console.log("LensCrew agent smoke (maintainer-only, live CLIs)");
  console.log(`timeout per step: ${timeoutMs}ms`);
  console.log(`pinned versions: ${VERSIONS_PATH}`);
  console.log("");

  let ok = 0;
  let skipped = 0;
  let failed = 0;

  for (const spec of SPECS) {
    if (only !== null && spec.kind !== only) continue;
    const pin = pins.pinned[spec.pinKey];
    try {
      const result = await smokeOne(spec, pin, timeoutMs);
      if (result === "ok") ok += 1;
      else skipped += 1;
    } catch (error) {
      failed += 1;
      console.error(`FAIL ${error instanceof Error ? error.message : String(error)}`);
    }
    console.log("");
  }

  console.log(`done: ok=${ok} skip=${skipped} fail=${failed}`);
  if (ok + skipped === 0 && failed === 0) {
    console.error("No agents selected / nothing to run.");
    process.exit(2);
  }
  if (failed > 0) process.exit(1);
  if (ok === 0) {
    console.warn("All agents skipped (none installed). Install CLIs to exercise live smoke.");
    process.exit(0);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
