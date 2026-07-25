// 自架哑中继:在 mac 与 phone 之间按 roomId 双向转发帧原文。
// 它对帧完全不解析——握手控制帧也从它身上过,但安全性全部由 E2EE 承担,
// relay 被攻破最多丢可用性,拿不到明文。所以这里零状态、不缓冲、不鉴权。

import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

export type RelayRole = "mac" | "phone";

export interface RelayServerOptions {
  /** 固定窗口限流:全部 HTTP 请求,默认 120/min */
  httpLimitPerMinute?: number;
  /** 固定窗口限流:新建 SSE 连接,默认 60/min */
  streamLimitPerMinute?: number;
  now?: () => number;
  log?: (line: string) => void;
}

const ROOM_ID_PATTERN = /^[A-Za-z0-9-]{8,64}$/;
const MAX_FRAME_BYTES = 1024 * 1024;
const HEARTBEAT_MS = 15_000;
const RATE_WINDOW_MS = 60_000;

const SSE_HEADERS = {
  "content-type": "text/event-stream; charset=utf-8",
  "cache-control": "no-cache, no-transform",
  connection: "keep-alive",
  "x-accel-buffering": "no",
} as const;

interface Room {
  mac?: ServerResponse;
  phone?: ServerResponse;
}

/** 固定窗口够用:relay 只防滥用不防精确 DoS,滑动窗口的复杂度在这不值 */
class FixedWindowLimiter {
  readonly #limit: number;
  readonly #now: () => number;
  #hits = new Map<string, { windowStart: number; count: number }>();

  constructor(limit: number, now: () => number) {
    this.#limit = limit;
    this.#now = now;
  }

  allow(key: string): boolean {
    const now = this.#now();
    // map 只增不减会被海量 IP 撑爆,超过阈值时顺手清掉过期窗口
    if (this.#hits.size > 4096) {
      for (const [k, v] of this.#hits) {
        if (now - v.windowStart >= RATE_WINDOW_MS) this.#hits.delete(k);
      }
    }
    const entry = this.#hits.get(key);
    if (entry === undefined || now - entry.windowStart >= RATE_WINDOW_MS) {
      this.#hits.set(key, { windowStart: now, count: 1 });
      return true;
    }
    entry.count += 1;
    return entry.count <= this.#limit;
  }
}

/** 日志里 roomId 只留 SHA-256 前 8 位:relay 日志可能进第三方采集,不能凭它反查房间 */
function roomTag(roomId: string): string {
  return createHash("sha256").update(roomId).digest("hex").slice(0, 8);
}

function otherRole(role: RelayRole): RelayRole {
  return role === "mac" ? "phone" : "mac";
}

export function createRelayServer(options: RelayServerOptions = {}): Server {
  const now = options.now ?? Date.now;
  const log = options.log ?? (() => {});
  const httpLimiter = new FixedWindowLimiter(options.httpLimitPerMinute ?? 120, now);
  const streamLimiter = new FixedWindowLimiter(options.streamLimitPerMinute ?? 60, now);
  const rooms = new Map<string, Room>();

  const heartbeat = setInterval(() => {
    for (const room of rooms.values()) {
      room.mac?.write(": ping\n\n");
      room.phone?.write(": ping\n\n");
    }
  }, HEARTBEAT_MS);
  heartbeat.unref();

  const server = createServer((request, response) => {
    void route(request, response).catch((error: unknown) => {
      sendJSON(response, 500, { error: error instanceof Error ? error.message : String(error) });
    });
  });

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const room of rooms.values()) {
      room.mac?.end();
      room.phone?.end();
    }
    rooms.clear();
  });

  return server;

  async function route(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const ip = request.socket.remoteAddress ?? "unknown";
    if (!httpLimiter.allow(ip)) {
      sendJSON(response, 429, { error: "rate limited" });
      return;
    }

    const url = new URL(request.url ?? "/", "http://localhost");
    if (request.method === "GET" && url.pathname === "/health") {
      sendJSON(response, 200, { ok: true });
      return;
    }

    const match = /^\/v1\/rooms\/([^/]+)\/(stream|send)$/.exec(url.pathname);
    if (match === null) {
      sendJSON(response, 404, { error: "not found" });
      return;
    }
    const roomId = match[1] ?? "";
    const action = match[2] ?? "";
    if (!ROOM_ID_PATTERN.test(roomId)) {
      sendJSON(response, 400, { error: "invalid roomId" });
      return;
    }
    const role = url.searchParams.get("role");
    if (role !== "mac" && role !== "phone") {
      sendJSON(response, 400, { error: "role must be mac or phone" });
      return;
    }

    if (request.method === "GET" && action === "stream") {
      if (!streamLimiter.allow(ip)) {
        sendJSON(response, 429, { error: "rate limited" });
        return;
      }
      openStream(roomId, role, response);
      return;
    }
    if (request.method === "POST" && action === "send") {
      await handleSend(roomId, role, request, response);
      return;
    }
    sendJSON(response, 404, { error: "not found" });
  }

  function openStream(roomId: string, role: RelayRole, response: ServerResponse): void {
    response.writeHead(200, SSE_HEADERS);
    response.flushHeaders();
    // 先给一个 body 字节,让客户端(URLSession/fetch)立刻拿到响应而不是等首帧
    response.write(": connected\n\n");

    let room = rooms.get(roomId);
    if (room === undefined) {
      room = {};
      rooms.set(roomId, room);
    }

    const previous = room[role];
    if (previous !== undefined) {
      // 同房间同角色只保留最新连接:旧的明确告知被顶替再关,免得它盲目重连打架
      previous.write(relayFrame({ evicted: true }));
      previous.end();
    }
    room[role] = response;
    log(`stream open room=${roomTag(roomId)} role=${role}`);

    const peer = room[otherRole(role)];
    if (peer !== undefined) {
      peer.write(relayFrame({ peer: "up" }));
      response.write(relayFrame({ peer: "up" }));
    }

    response.on("close", () => {
      const current = rooms.get(roomId);
      // 已被顶替的旧连接关闭时不算对端掉线,新连接还活着
      if (current === undefined || current[role] !== response) return;
      delete current[role];
      log(`stream close room=${roomTag(roomId)} role=${role}`);
      const survivor = current[otherRole(role)];
      if (survivor !== undefined) {
        survivor.write(relayFrame({ peer: "down" }));
      } else {
        rooms.delete(roomId);
      }
    });
  }

  async function handleSend(
    roomId: string,
    role: RelayRole,
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    let frame: string;
    try {
      frame = await readBody(request);
    } catch (error) {
      sendJSON(response, 413, { error: error instanceof Error ? error.message : String(error) });
      return;
    }
    // SSE 下行「一条 data: 行即一帧」,帧原文里出现换行会撕破帧边界
    if (frame.includes("\n") || frame.includes("\r")) {
      sendJSON(response, 400, { error: "frame must be a single line" });
      return;
    }
    const peer = rooms.get(roomId)?.[otherRole(role)];
    if (peer === undefined) {
      // 不缓冲:relay 零状态,离线补发由 E2EE 两端自己重握手/重发解决
      sendJSON(response, 202, { delivered: false });
      return;
    }
    peer.write(`data: ${frame}\n\n`);
    sendJSON(response, 200, { delivered: true });
  }
}

function relayFrame(payload: unknown): string {
  return `event: relay\ndata: ${JSON.stringify(payload)}\n\n`;
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = chunk as Buffer;
    size += buffer.length;
    if (size > MAX_FRAME_BYTES) throw new Error("frame too large");
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function sendJSON(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}
