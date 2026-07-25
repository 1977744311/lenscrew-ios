import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";

import type { BridgeEvent, ClientCommand } from "../protocol/events.ts";
import type { SessionHub } from "../session/hub.ts";

/**
 * 下行选 SSE 而不是 WebSocket：bridge 要保持零第三方依赖，
 * node:http 原生就能发 SSE，而 WebSocket 服务端得自己写帧解析或引包。
 * iOS 侧 URLSession.bytes(for:).lines 正好是逐行 AsyncSequence，代价很低。
 *
 * M0 只在局域网/Tailscale 内直连，token 只防误连不是安全边界；
 * 端到端加密与二维码配对是下一步。
 */
export interface BridgeServerOptions {
  hub: SessionHub;
  token: string;
  host: string;
  port: number;
}

const SSE_HEADERS = {
  "content-type": "text/event-stream; charset=utf-8",
  "cache-control": "no-cache, no-transform",
  connection: "keep-alive",
  // 反代默认会缓冲 SSE，缓冲了就没有流式可言
  "x-accel-buffering": "no",
} as const;

/** 心跳：手机端切后台再回来时，靠这个尽快发现连接已死 */
const HEARTBEAT_MS = 15_000;

export function createBridgeServer(options: BridgeServerOptions): Server {
  const { hub, token } = options;
  const subscribers = new Set<ServerResponse>();

  hub.onEvent((event) => {
    const frame = formatFrame(event);
    for (const response of subscribers) response.write(frame);
  });

  const heartbeat = setInterval(() => {
    for (const response of subscribers) response.write(": ping\n\n");
  }, HEARTBEAT_MS);
  heartbeat.unref();

  const server = createServer((request, response) => {
    void route(request, response).catch((error: unknown) => {
      sendJSON(response, 500, {
        error: error instanceof Error ? error.message : String(error),
      });
    });
  });

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const response of subscribers) response.end();
    subscribers.clear();
  });

  return server;

  async function route(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const url = new URL(request.url ?? "/", "http://localhost");

    if (request.method === "GET" && url.pathname === "/health") {
      sendJSON(response, 200, { ok: true });
      return;
    }

    if (!authorized(request, token)) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/events") {
      openStream(url, response);
      return;
    }

    if (request.method === "POST" && url.pathname === "/command") {
      const command = (await readJSON(request)) as ClientCommand;
      if (command.type === "subscribe") {
        // 补齐断档：只补这一个客户端要的那段，不打扰其他订阅者
        sendJSON(response, 200, {
          events: hub.replay(command.sessionId, command.fromSeq),
        });
        return;
      }
      await hub.handle(command);
      sendJSON(response, 200, { ok: true });
      return;
    }

    sendJSON(response, 404, { error: "not found" });
  }

  function openStream(url: URL, response: ServerResponse): void {
    response.writeHead(200, SSE_HEADERS);
    subscribers.add(response);
    response.on("close", () => subscribers.delete(response));

    const sessionId = url.searchParams.get("sessionId");
    if (sessionId) {
      const fromSeq = Number(url.searchParams.get("fromSeq") ?? "0");
      for (const event of hub.replay(sessionId, fromSeq)) {
        response.write(formatFrame(event));
      }
    } else {
      for (const session of hub.listSessions()) {
        response.write(
          formatFrame({ type: "sessionCreated", seq: 0, session }),
        );
      }
    }
  }
}

function formatFrame(event: BridgeEvent): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}

function authorized(request: IncomingMessage, token: string): boolean {
  const header = request.headers.authorization ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  const expected = Buffer.from(token);
  const actual = Buffer.from(presented);
  // 长度不等时 timingSafeEqual 会抛，先挡掉；长度本身不是秘密
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

async function readJSON(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = chunk as Buffer;
    size += buffer.length;
    // 手机发过来的只有指令和提示词，超过 1 MiB 一定是异常
    if (size > 1024 * 1024) throw new Error("请求体过大");
    chunks.push(buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
}

function sendJSON(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}
