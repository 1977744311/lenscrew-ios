import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";

import type { BridgeEvent, ClientCommand } from "../protocol/events.ts";
import type { GitRequest } from "../protocol/git.ts";
import { runGitRequest, type GitRunner } from "../git/service.ts";
import type { SessionHub } from "../session/hub.ts";
import type { HostFrame } from "../secure/channel.ts";
import type { SecureGateway } from "../secure/secureGateway.ts";

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
  /** 传入即启用 /e2ee/stream + /e2ee/send 本地直连 E2EE 端点 */
  gateway?: SecureGateway;
  /** 传入即启用 /admin/pairing(仅回环来源 + 独立 Bearer token) */
  admin?: {
    token: string;
    reopenPairing: () => { expiresAtMs: number; pairPayload: unknown };
  };
  /** git 面板的执行器；缺省用真 git，测试注入 stub */
  gitRunner?: GitRunner;
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

/** 单 device 的 E2EE 下行:流断开期间的出站帧先排队,重连后一次性补上 */
interface E2eeChannel {
  stream: ServerResponse | null;
  queue: string[];
}

/** 队列防的是「POST 先到、stream 后开」的窗口期,不是离线缓存,不用太深 */
const E2EE_QUEUE_LIMIT = 256;

export function createBridgeServer(options: BridgeServerOptions): Server {
  const { hub, token, gateway, admin } = options;
  const gitRunner = options.gitRunner ?? runGitRequest;
  const subscribers = new Set<ServerResponse>();
  const e2eeChannels = new Map<string, E2eeChannel>();
  /** encryptedEnvelope 只带 roomId,靠 clientHello 学到的映射把回帧路由回来源 device */
  const e2eeRoomToDevice = new Map<string, string>();

  hub.onEvent((event) => {
    const frame = formatFrame(event);
    for (const response of subscribers) response.write(frame);
  });

  const heartbeat = setInterval(() => {
    for (const response of subscribers) response.write(": ping\n\n");
    for (const channel of e2eeChannels.values()) channel.stream?.write(": ping\n\n");
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
    for (const channel of e2eeChannels.values()) channel.stream?.end();
    e2eeChannels.clear();
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

    if (admin !== undefined && request.method === "POST" && url.pathname === "/admin/pairing") {
      // admin 面只给本机 CLI 用:回环来源 + 与访问口令独立的 adminToken
      if (!isLoopback(request)) {
        sendJSON(response, 403, { error: "loopback only" });
        return;
      }
      if (!authorized(request, admin.token)) {
        sendJSON(response, 401, { error: "unauthorized" });
        return;
      }
      const reopened = admin.reopenPairing();
      sendJSON(response, 200, { ok: true, ...reopened });
      return;
    }

    // /e2ee/* 不查访问口令:配对前 phone 拿不到 token,安全性由 E2EE 握手本身保证
    if (gateway !== undefined && request.method === "GET" && url.pathname === "/e2ee/stream") {
      const device = url.searchParams.get("device");
      if (device === null || device === "") {
        sendJSON(response, 400, { error: "device query is required" });
        return;
      }
      openE2eeStream(device, response);
      return;
    }

    if (gateway !== undefined && request.method === "POST" && url.pathname === "/e2ee/send") {
      const frame = await readJSON(request);
      const device = resolveE2eeDevice(frame);
      if (device === undefined) {
        sendJSON(response, 400, { error: "cannot route frame to a device" });
        return;
      }
      gateway.handleFrame(frame, e2eeSink(device));
      // 应答帧一律走 stream 下行,这里只确认收到
      sendJSON(response, 202, { ok: true });
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

    if (request.method === "POST" && url.pathname === "/git") {
      const gitRequest = (await readJSON(request)) as GitRequest;
      try {
        sendJSON(response, 200, { ok: true, git: await gitRunner(gitRequest) });
      } catch (error) {
        // git 失败是业务结果不是传输故障：stderr 正是要给用户看的内容
        sendJSON(response, 200, {
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      return;
    }

    sendJSON(response, 404, { error: "not found" });
  }

  function openStream(url: URL, response: ServerResponse): void {
    response.writeHead(200, SSE_HEADERS);
    response.flushHeaders();
    // 开流就先写一行注释当序幕。实测 URLSession 要等到第一个 body 字节才肯把响应
    // 交给调用方，而新客户端接进来时往往没有历史可补发，第一个字节就成了心跳——
    // 客户端会一直卡在建流上，把整个心跳周期都等掉。注释行会被 SSE 解码器忽略。
    response.write(": connected\n\n");
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
    // 额度不进会话重放窗口，接入时单独补发缓存的最新快照
    for (const quota of hub.latestQuota()) {
      response.write(formatFrame({ type: "quotaUpdated", seq: 0, quota }));
    }
  }

  function openE2eeStream(device: string, response: ServerResponse): void {
    response.writeHead(200, SSE_HEADERS);
    response.flushHeaders();
    response.write(": connected\n\n");

    let channel = e2eeChannels.get(device);
    if (channel === undefined) {
      channel = { stream: null, queue: [] };
      e2eeChannels.set(device, channel);
    }
    // 同 device 新流顶替旧流:phone 重连时旧连接往往还没超时
    channel.stream?.end();
    channel.stream = response;
    for (const frame of channel.queue) response.write(frame);
    channel.queue = [];

    response.on("close", () => {
      const current = e2eeChannels.get(device);
      if (current?.stream === response) current.stream = null;
    });
  }

  /** io.send 的目标由「本次 handleFrame 的来源 device」决定,闭包绑到该 device 的下行 */
  function e2eeSink(device: string): (frame: HostFrame) => void {
    return (frame) => {
      let channel = e2eeChannels.get(device);
      if (channel === undefined) {
        channel = { stream: null, queue: [] };
        e2eeChannels.set(device, channel);
      }
      const data = `data: ${JSON.stringify(frame)}\n\n`;
      if (channel.stream !== null) {
        channel.stream.write(data);
      } else {
        channel.queue.push(data);
        if (channel.queue.length > E2EE_QUEUE_LIMIT) channel.queue.shift();
      }
    };
  }

  function resolveE2eeDevice(frame: unknown): string | undefined {
    if (typeof frame !== "object" || frame === null) return undefined;
    const f = frame as Record<string, unknown>;
    const phoneDeviceId = f["phoneDeviceId"];
    const roomId = f["roomId"];
    if (typeof phoneDeviceId === "string" && phoneDeviceId !== "") {
      // clientHello / clientAuth 自带 device,顺手记下 room→device 供后续信封路由
      if (typeof roomId === "string" && roomId !== "") {
        e2eeRoomToDevice.set(roomId, phoneDeviceId);
      }
      return phoneDeviceId;
    }
    if (typeof roomId === "string" && roomId !== "") {
      return e2eeRoomToDevice.get(roomId);
    }
    return undefined;
  }
}

function formatFrame(event: BridgeEvent): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}

function isLoopback(request: IncomingMessage): boolean {
  const address = request.socket.remoteAddress ?? "";
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
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
