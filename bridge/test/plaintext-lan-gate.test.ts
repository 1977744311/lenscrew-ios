import test from "node:test";
import assert from "node:assert/strict";
import { get, request, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { createBridgeServer, isLoopbackListenHost } from "../src/transport/server.ts";
import type { SessionHub } from "../src/session/hub.ts";
import type {
  AgentQuotaSnapshot,
  AgentSession,
  BridgeEvent,
  ClientCommand,
} from "../src/protocol/events.ts";
import type { GitRunner } from "../src/git/service.ts";

const TOKEN = "plaintext-lan-test-token";

class FakeHub {
  readonly #listeners = new Set<(event: BridgeEvent) => void>();
  handled: ClientCommand[] = [];

  onEvent(listener: (event: BridgeEvent) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  async handle(command: ClientCommand): Promise<void> {
    this.handled.push(command);
  }
  replay(): BridgeEvent[] {
    return [];
  }
  listSessions(): AgentSession[] {
    return [];
  }
  latestQuota(): AgentQuotaSnapshot[] {
    return [];
  }
}

async function startHarness(opts: {
  host: string;
  allowPlaintextLan?: boolean;
}): Promise<{ server: Server; base: string; hub: FakeHub }> {
  const hub = new FakeHub();
  const gitRunner: GitRunner = async () => ({
    kind: "status",
    status: {
      branch: "main",
      upstream: null,
      ahead: null,
      behind: null,
      staged: [],
      unstaged: [],
      stashCount: 0,
    },
  });
  const server = createBridgeServer({
    hub: hub as unknown as SessionHub,
    token: TOKEN,
    host: opts.host,
    port: 0,
    ...(opts.allowPlaintextLan === true ? { allowPlaintextLan: true } : {}),
    gitRunner,
  });
  // 测试里始终绑回环口，避免真开 LAN 端口；门控看的是 options.host，不是 bind 地址
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return { server, base: `http://127.0.0.1:${port}`, hub };
}

function stop(server: Server): void {
  server.close();
  server.closeAllConnections();
}

function postJSON(
  url: string,
  body: unknown,
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = request(
      url,
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${TOKEN}`,
          "content-type": "application/json",
          "content-length": Buffer.byteLength(payload),
        },
      },
      (response: IncomingMessage) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve({
            status: response.statusCode ?? 0,
            body: text === "" ? null : JSON.parse(text),
          });
        });
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

function getEvents(url: string): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    get(
      url,
      { headers: { authorization: `Bearer ${TOKEN}`, accept: "text/event-stream" } },
      (response: IncomingMessage) => {
        if (response.statusCode !== 200) {
          const chunks: Buffer[] = [];
          response.on("data", (chunk: Buffer) => chunks.push(chunk));
          response.on("end", () => {
            const text = Buffer.concat(chunks).toString("utf8");
            resolve({
              status: response.statusCode ?? 0,
              body: text === "" ? null : JSON.parse(text),
            });
          });
          return;
        }
        // SSE 200：立刻关掉，只关心门控放行
        response.destroy();
        resolve({ status: 200, body: null });
      },
    ).on("error", (error: NodeJS.ErrnoException) => {
      // destroy 可能触发 ECONNRESET，对门控测试可忽略
      if (error.code === "ECONNRESET") return;
      reject(error);
    });
  });
}

test("isLoopbackListenHost 识别回环监听地址", () => {
  assert.equal(isLoopbackListenHost("127.0.0.1"), true);
  assert.equal(isLoopbackListenHost("localhost"), true);
  assert.equal(isLoopbackListenHost("::1"), true);
  assert.equal(isLoopbackListenHost("[::1]"), true);
  assert.equal(isLoopbackListenHost("0.0.0.0"), false);
  assert.equal(isLoopbackListenHost("192.168.1.10"), false);
});

test("回环监听：明文 /command /git /events 放行", async () => {
  const { server, base, hub } = await startHarness({ host: "127.0.0.1" });
  try {
    const command = await postJSON(`${base}/command`, { type: "listSessions" });
    assert.equal(command.status, 200);
    assert.deepEqual(command.body, { ok: true });
    assert.equal(hub.handled.length, 1);

    const git = await postJSON(`${base}/git`, {
      op: "status",
      root: "/tmp",
    });
    assert.equal(git.status, 200);
    assert.equal((git.body as { ok: boolean }).ok, true);

    const events = await getEvents(`${base}/events`);
    assert.equal(events.status, 200);
  } finally {
    stop(server);
  }
});

test("非回环监听：明文 /command /git /events 默认 403，须 --allow-plaintext-lan", async () => {
  const blocked = await startHarness({ host: "0.0.0.0" });
  try {
    const command = await postJSON(`${blocked.base}/command`, { type: "listSessions" });
    assert.equal(command.status, 403);
    assert.match(String((command.body as { error: string }).error), /plaintext/);
    assert.equal(blocked.hub.handled.length, 0);

    const git = await postJSON(`${blocked.base}/git`, {
      op: "status",
      root: "/tmp",
    });
    assert.equal(git.status, 403);

    const events = await getEvents(`${blocked.base}/events`);
    assert.equal(events.status, 403);
  } finally {
    stop(blocked.server);
  }

  const allowed = await startHarness({ host: "0.0.0.0", allowPlaintextLan: true });
  try {
    const command = await postJSON(`${allowed.base}/command`, { type: "listSessions" });
    assert.equal(command.status, 200);
    assert.deepEqual(command.body, { ok: true });
  } finally {
    stop(allowed.server);
  }
});
