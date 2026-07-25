// bridge 侧的 relay 客户端:以 role=mac 常驻自己 macDeviceId 的房间,
// 下行消费 SSE(一条 data: 行即一帧),上行全部走 POST /send。
// 帧对 relay 不透明,这里只做搬运与重连,内容安全由 SecureGateway/E2EE 负责。

import { get as httpGet, request as httpRequest } from "node:http";
import { get as httpsGet, request as httpsRequest } from "node:https";
import type { IncomingMessage } from "node:http";

import type { HostFrame } from "../secure/channel.ts";
import type { SecureGateway } from "../secure/secureGateway.ts";

export interface RelayClientOptions {
  /** relay 基地址,如 https://relay.example */
  relayUrl: string;
  /** 房间号 = macDeviceId,与配对 payload 中 phone 拿到的一致 */
  roomId: string;
  gateway: SecureGateway;
  log?: (line: string) => void;
  /** 测试把退避调快用;缺省 250ms ×2 封顶 10s */
  backoff?: { initialMs: number; maxMs: number };
}

export interface RelayClient {
  close(): void;
}

interface SseEvent {
  event: string;
  data: string;
}

/** 极简 SSE 解码:只认 event:/data:/注释行,一个空行分发一个事件 */
function createSseParser(onEvent: (event: SseEvent) => void): (chunk: string) => void {
  let buffer = "";
  let eventName = "";
  let dataLines: string[] = [];
  return (chunk) => {
    buffer += chunk;
    let newline = buffer.indexOf("\n");
    while (newline !== -1) {
      const line = buffer.slice(0, newline).replace(/\r$/, "");
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
      if (line === "") {
        if (dataLines.length > 0) {
          onEvent({ event: eventName === "" ? "message" : eventName, data: dataLines.join("\n") });
        }
        eventName = "";
        dataLines = [];
      } else if (line.startsWith("data:")) {
        dataLines.push(line.slice(5).replace(/^ /, ""));
      } else if (line.startsWith("event:")) {
        eventName = line.slice(6).replace(/^ /, "");
      }
      // 其余(注释心跳、id: 等)一律忽略
    }
  };
}

export function startRelayClient(options: RelayClientOptions): RelayClient {
  const log = options.log ?? (() => {});
  const base = options.relayUrl.replace(/\/+$/, "");
  const streamUrl = new URL(`${base}/v1/rooms/${options.roomId}/stream?role=mac`);
  const sendUrl = new URL(`${base}/v1/rooms/${options.roomId}/send?role=mac`);
  const isHttps = streamUrl.protocol === "https:";
  const initialBackoffMs = options.backoff?.initialMs ?? 250;
  const maxBackoffMs = options.backoff?.maxMs ?? 10_000;

  let closed = false;
  let backoffMs = initialBackoffMs;
  let current: IncomingMessage | null = null;
  let reconnectTimer: NodeJS.Timeout | null = null;

  const sink = (frame: HostFrame): void => postFrame(JSON.stringify(frame));

  connect();

  return {
    close() {
      closed = true;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      current?.destroy();
    },
  };

  function connect(): void {
    if (closed) return;
    const getter = isHttps ? httpsGet : httpGet;
    // agent:false:不进 keep-alive 连接池。池里的空闲 socket 在 relay 掉线时
    // 会冒出无人接的 ECONNRESET 直接炸进程,而帧流量低,省这点握手不值
    const request = getter(streamUrl, { headers: { accept: "text/event-stream" }, agent: false }, (response) => {
      if (response.statusCode !== 200) {
        log(`relay stream 拒绝: HTTP ${response.statusCode ?? 0}`);
        response.resume();
        scheduleReconnect();
        return;
      }
      current = response;
      // 连上就复位退避:接下来的断线是新故障,不该继承旧惩罚
      backoffMs = initialBackoffMs;
      log("relay stream 已连接");
      const parse = createSseParser(handleEvent);
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => parse(chunk));
      // relay 掉线时 response 会先冒 ECONNRESET 再 close;不接住会炸掉进程,重连交给 close
      response.on("error", () => {});
      response.on("close", () => {
        current = null;
        if (!closed) {
          log("relay stream 断开");
          scheduleReconnect();
        }
      });
    });
    request.on("error", (error) => {
      log(`relay stream 连接失败: ${error.message}`);
      scheduleReconnect();
    });
  }

  function handleEvent(event: SseEvent): void {
    if (event.event === "relay") {
      // 对端状态只做日志:掉线无需动作,E2EE 会话在 phone 回来后照常续用
      log(`relay 状态: ${event.data}`);
      return;
    }
    let frame: unknown;
    try {
      frame = JSON.parse(event.data);
    } catch {
      log("relay 下行帧不是 JSON,丢弃");
      return;
    }
    options.gateway.handleFrame(frame, sink);
  }

  function scheduleReconnect(): void {
    if (closed || reconnectTimer !== null) return;
    const delay = backoffMs;
    backoffMs = Math.min(backoffMs * 2, maxBackoffMs);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  }

  function postFrame(body: string): void {
    const requester = isHttps ? httpsRequest : httpRequest;
    const request = requester(
      sendUrl,
      {
        method: "POST",
        agent: false,
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "content-length": Buffer.byteLength(body),
        },
      },
      (response) => {
        // delivered:false 表示 phone 不在线,帧已丢——E2EE 层靠重握手恢复,不重试
        response.on("error", () => {});
        response.resume();
      },
    );
    request.on("error", (error) => log(`relay 上行失败: ${error.message}`));
    request.end(body);
  }
}
