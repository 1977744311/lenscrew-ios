import test from "node:test";
import assert from "node:assert/strict";
import { get, request, type IncomingMessage } from "node:http";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";

import { createRelayServer, type RelayServerOptions } from "../src/relay/relayServer.ts";

// MARK: - 测试台

async function startRelay(options: RelayServerOptions = {}): Promise<{ server: Server; base: string }> {
  const server = createRelayServer(options);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return { server, base: `http://127.0.0.1:${port}` };
}

function stopRelay(server: Server): void {
  server.close();
  // SSE 长连接不断,close 永远等不到;测试里直接掐掉
  server.closeAllConnections();
}

interface SseEvent {
  event: string;
  data: string;
}

interface SseStream {
  status: number;
  events: SseEvent[];
  closed: boolean;
  close(): void;
}

/** 极简 SSE 测试客户端:headers 一到就 resolve,事件持续进 events */
function openSse(url: string): Promise<SseStream> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const req = get(url, { headers: { accept: "text/event-stream" } }, (response: IncomingMessage) => {
      const stream: SseStream = {
        status: response.statusCode ?? 0,
        events: [],
        closed: false,
        close: () => req.destroy(),
      };
      settled = true;
      if (response.statusCode !== 200) {
        response.resume();
        resolve(stream);
        return;
      }
      let buffer = "";
      let eventName = "";
      let dataLines: string[] = [];
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          newline = buffer.indexOf("\n");
          if (line === "") {
            if (dataLines.length > 0) {
              stream.events.push({
                event: eventName === "" ? "message" : eventName,
                data: dataLines.join("\n"),
              });
            }
            eventName = "";
            dataLines = [];
          } else if (line.startsWith("data:")) {
            dataLines.push(line.slice(5).replace(/^ /, ""));
          } else if (line.startsWith("event:")) {
            eventName = line.slice(6).replace(/^ /, "");
          }
        }
      });
      // 服务端主动掐流(顶替/关闭)时会先冒 ECONNRESET,测试只关心 closed 状态
      response.on("error", () => {});
      response.on("close", () => {
        stream.closed = true;
      });
      resolve(stream);
    });
    req.on("error", (error) => {
      if (!settled) reject(error);
    });
  });
}

/** 不走 fetch:undici 的 keep-alive 连接池会拖住测试进程 */
function httpCall(
  method: string,
  url: string,
  body?: string,
): Promise<{ status: number; json: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = request(url, { method, agent: false }, (response) => {
      const chunks: Buffer[] = [];
      response.on("error", reject);
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => {
        resolve({
          status: response.statusCode ?? 0,
          json: JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>,
        });
      });
    });
    req.on("error", reject);
    req.end(body);
  });
}

async function waitFor(check: () => boolean, what: string, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) assert.fail(`等待超时: ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

const ROOM = "room-relay-test-0001";

function dataEvents(stream: SseStream): string[] {
  return stream.events.filter((e) => e.event === "message").map((e) => e.data);
}

function relayEvents(stream: SseStream): string[] {
  return stream.events.filter((e) => e.event === "relay").map((e) => e.data);
}

// MARK: - 基本面

test("GET /health 返回 ok", async () => {
  const { server, base } = await startRelay();
  try {
    const reply = await httpCall("GET", `${base}/health`);
    assert.equal(reply.status, 200);
    assert.deepEqual(reply.json, { ok: true });
  } finally {
    stopRelay(server);
  }
});

test("roomId 与 role 校验", async () => {
  const { server, base } = await startRelay();
  try {
    // roomId 太短
    const short = await httpCall("POST", `${base}/v1/rooms/abc/send?role=mac`, "x");
    assert.equal(short.status, 400);
    // roomId 含非法字符
    const bad = await openSse(`${base}/v1/rooms/room_with_underscore/stream?role=mac`);
    assert.equal(bad.status, 400);
    // role 非法
    const role = await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=tv`, "x");
    assert.equal(role.status, 400);
    const noRole = await openSse(`${base}/v1/rooms/${ROOM}/stream`);
    assert.equal(noRole.status, 400);
  } finally {
    stopRelay(server);
  }
});

// MARK: - 转发

test("mac 与 phone 双向转发,帧原文不动", async () => {
  const { server, base } = await startRelay();
  try {
    const mac = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    const phone = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=phone`);

    const phoneFrame = '{"kind":"clientHello","roomId":"r","opaque":true}';
    const sent = await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=phone`, phoneFrame);
    assert.equal(sent.status, 200);
    assert.deepEqual(sent.json, { delivered: true });
    await waitFor(() => dataEvents(mac).length === 1, "mac 收到 phone 的帧");
    assert.deepEqual(dataEvents(mac), [phoneFrame]);

    const macFrame = '{"kind":"serverHello","填":"不是 JSON 也照转"}';
    const back = await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=mac`, macFrame);
    assert.deepEqual(back.json, { delivered: true });
    await waitFor(() => dataEvents(phone).length === 1, "phone 收到 mac 的帧");
    assert.deepEqual(dataEvents(phone), [macFrame]);

    mac.close();
    phone.close();
  } finally {
    stopRelay(server);
  }
});

test("对端不在线回 202 delivered:false,且不缓冲", async () => {
  const { server, base } = await startRelay();
  try {
    const lost = await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=phone`, "orphan-frame");
    assert.equal(lost.status, 202);
    assert.deepEqual(lost.json, { delivered: false });

    // mac 事后上线,不应收到 orphan-frame;再发一帧,只收到新帧
    const mac = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=phone`, "fresh-frame");
    await waitFor(() => dataEvents(mac).length >= 1, "mac 收到新帧");
    assert.deepEqual(dataEvents(mac), ["fresh-frame"]);
    mac.close();
  } finally {
    stopRelay(server);
  }
});

// MARK: - 对端状态与顶替

test("对端上线/掉线推 relay 事件,双方都能看到 up", async () => {
  const { server, base } = await startRelay();
  try {
    const mac = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    assert.deepEqual(relayEvents(mac), [], "独自在房间时没有 peer 事件");

    const phone = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=phone`);
    await waitFor(() => relayEvents(mac).length === 1, "mac 看到 phone 上线");
    assert.deepEqual(relayEvents(mac), ['{"peer":"up"}']);
    // 连接建立时对端已在,也立刻推 up
    await waitFor(() => relayEvents(phone).length === 1, "phone 立刻看到 mac 已在");
    assert.deepEqual(relayEvents(phone), ['{"peer":"up"}']);

    phone.close();
    await waitFor(() => relayEvents(mac).length === 2, "mac 看到 phone 掉线");
    assert.deepEqual(relayEvents(mac).at(-1), '{"peer":"down"}');
    mac.close();
  } finally {
    stopRelay(server);
  }
});

test("同房间同角色新连接顶替旧连接,顶替不算对端掉线", async () => {
  const { server, base } = await startRelay();
  try {
    const phone = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=phone`);
    const mac1 = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    await waitFor(() => relayEvents(phone).length === 1, "phone 看到 mac1 上线");

    const mac2 = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    await waitFor(() => mac1.closed, "旧连接被服务端关闭");
    assert.ok(relayEvents(mac1).includes('{"evicted":true}'), "旧连接收到 evicted 通知");

    // phone 视角:mac2 上线又推了一次 up,但绝不能出现 down
    await waitFor(() => relayEvents(phone).length === 2, "phone 看到 mac2 上线");
    assert.ok(!relayEvents(phone).some((d) => d.includes("down")), "顶替过程不产生 peer down");

    // 转发落到新连接
    await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=phone`, "to-mac2");
    await waitFor(() => dataEvents(mac2).length === 1, "mac2 收到帧");
    assert.deepEqual(dataEvents(mac2), ["to-mac2"]);
    assert.deepEqual(dataEvents(mac1), []);

    phone.close();
    mac2.close();
  } finally {
    stopRelay(server);
  }
});

// MARK: - 限流与帧约束

test("HTTP 固定窗口限流,超限回 429", async () => {
  const { server, base } = await startRelay({ httpLimitPerMinute: 3 });
  try {
    for (let index = 0; index < 3; index += 1) {
      const reply = await httpCall("GET", `${base}/health`);
      assert.equal(reply.status, 200);
    }
    const blocked = await httpCall("GET", `${base}/health`);
    assert.equal(blocked.status, 429);
  } finally {
    stopRelay(server);
  }
});

test("新 SSE 连接单独限流,超限回 429", async () => {
  const { server, base } = await startRelay({ streamLimitPerMinute: 1 });
  try {
    const first = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=mac`);
    assert.equal(first.status, 200);
    const second = await openSse(`${base}/v1/rooms/${ROOM}/stream?role=phone`);
    assert.equal(second.status, 429);
    first.close();
  } finally {
    stopRelay(server);
  }
});

test("超过 1MiB 或含换行的帧被拒", async () => {
  const { server, base } = await startRelay();
  try {
    const huge = await httpCall(
      "POST",
      `${base}/v1/rooms/${ROOM}/send?role=phone`,
      "x".repeat(1024 * 1024 + 1),
    );
    assert.equal(huge.status, 413);

    const multiline = await httpCall("POST", `${base}/v1/rooms/${ROOM}/send?role=phone`, "a\nb");
    assert.equal(multiline.status, 400);
  } finally {
    stopRelay(server);
  }
});
