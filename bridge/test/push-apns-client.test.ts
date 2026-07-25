import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";

import { createApnsClient } from "../src/push/apnsClient.ts";
import type { ApnsClientOptions } from "../src/push/apnsClient.ts";

const privateKeyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ type: "pkcs8", format: "pem" })
  .toString();

// ——http2 替身:只实现 ApnsHttp2Session/ApnsHttp2Stream 要求的最小面——

class FakeStream {
  written = "";
  #listeners = new Map<string, ((...args: never[]) => void)[]>();

  setEncoding(_encoding: string): void {}

  on(event: string, listener: (...args: never[]) => void): this {
    const list = this.#listeners.get(event) ?? [];
    list.push(listener);
    this.#listeners.set(event, list);
    return this;
  }

  end(data: string): void {
    this.written = data;
  }

  emit(event: string, ...args: unknown[]): void {
    for (const listener of this.#listeners.get(event) ?? []) {
      (listener as (...forwarded: unknown[]) => void)(...args);
    }
  }
}

class FakeSession {
  requests: { headers: Record<string, string>; stream: FakeStream }[] = [];
  closed = false;
  destroyed = false;
  #listeners = new Map<string, (() => void)[]>();

  request(headers: Record<string, string>): FakeStream {
    const stream = new FakeStream();
    this.requests.push({ headers, stream });
    return stream;
  }

  on(event: string, listener: () => void): this {
    const list = this.#listeners.get(event) ?? [];
    list.push(listener);
    this.#listeners.set(event, list);
    return this;
  }

  close(): void {
    this.closed = true;
  }

  emit(event: string): void {
    for (const listener of this.#listeners.get(event) ?? []) listener();
  }
}

function makeClient(overrides: Partial<ApnsClientOptions> = {}) {
  const sessions: FakeSession[] = [];
  const authorities: string[] = [];
  const client = createApnsClient({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "com.lenscrew.app",
    privateKeyPem,
    environment: "production",
    connectFn: (authority: string) => {
      authorities.push(authority);
      const session = new FakeSession();
      sessions.push(session);
      return session;
    },
    ...overrides,
  });
  return { client, sessions, authorities };
}

function respond(stream: FakeStream, status: number, body?: string, apnsId?: string): void {
  const headers: Record<string, string | number> = { ":status": status };
  if (apnsId !== undefined) headers["apns-id"] = apnsId;
  stream.emit("response", headers);
  if (body !== undefined) stream.emit("data", body);
  stream.emit("end");
}

test("send:POST /3/device/<token>、头部齐全、payload 原文透传", async () => {
  const { client, sessions, authorities } = makeClient();
  const payload = { aps: { alert: { title: "标题", body: "正文" } }, lenscrew: { kind: "approval" } };
  const promise = client.send({
    deviceToken: "device-token-1",
    payload,
    pushType: "alert",
    priority: 10,
    topic: "com.lenscrew.app",
    collapseId: "session-1",
  });

  assert.deepEqual(authorities, ["https://api.push.apple.com"]);
  const request = sessions[0]!.requests[0]!;
  assert.equal(request.headers[":method"], "POST");
  assert.equal(request.headers[":path"], "/3/device/device-token-1");
  assert.match(request.headers["authorization"]!, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.equal(request.headers["apns-topic"], "com.lenscrew.app");
  assert.equal(request.headers["apns-push-type"], "alert");
  assert.equal(request.headers["apns-priority"], "10");
  assert.equal(request.headers["apns-collapse-id"], "session-1");
  assert.equal(request.stream.written, JSON.stringify(payload));

  respond(request.stream, 200, undefined, "apns-id-1");
  assert.deepEqual(await promise, { status: 200, apnsId: "apns-id-1", tokenGone: false });
});

test("send:默认值(topic=bundleId、alert、priority 10、无 collapse 头)", async () => {
  const { client, sessions } = makeClient({ environment: "sandbox" });
  const promise = client.send({ deviceToken: "tok", payload: { aps: {} } });
  const request = sessions[0]!.requests[0]!;
  assert.equal(request.headers["apns-topic"], "com.lenscrew.app");
  assert.equal(request.headers["apns-push-type"], "alert");
  assert.equal(request.headers["apns-priority"], "10");
  assert.ok(!("apns-collapse-id" in request.headers));
  respond(request.stream, 200);
  await promise;
});

test("send:sandbox environment 连到沙箱主机", async () => {
  const { client, sessions, authorities } = makeClient({ environment: "sandbox" });
  const promise = client.send({ deviceToken: "tok", payload: {} });
  assert.deepEqual(authorities, ["https://api.sandbox.push.apple.com"]);
  respond(sessions[0]!.requests[0]!.stream, 200);
  await promise;
});

test("send:410 Unregistered 与 400 BadDeviceToken 都标记 tokenGone", async () => {
  const { client, sessions } = makeClient();

  const gone = client.send({ deviceToken: "tok-gone", payload: {} });
  respond(sessions[0]!.requests[0]!.stream, 410, '{"reason":"Unregistered"}');
  assert.deepEqual(await gone, { status: 410, reason: "Unregistered", tokenGone: true });

  const bad = client.send({ deviceToken: "tok-bad", payload: {} });
  respond(sessions[0]!.requests[1]!.stream, 400, '{"reason":"BadDeviceToken"}');
  assert.deepEqual(await bad, { status: 400, reason: "BadDeviceToken", tokenGone: true });

  const serverError = client.send({ deviceToken: "tok-ok", payload: {} });
  respond(sessions[0]!.requests[2]!.stream, 500, '{"reason":"InternalServerError"}');
  assert.deepEqual(await serverError, { status: 500, reason: "InternalServerError", tokenGone: false });
});

test("会话复用 + GOAWAY/关闭后重建", async () => {
  const { client, sessions } = makeClient();

  const first = client.send({ deviceToken: "a", payload: {} });
  respond(sessions[0]!.requests[0]!.stream, 200);
  await first;
  const second = client.send({ deviceToken: "b", payload: {} });
  respond(sessions[0]!.requests[1]!.stream, 200);
  await second;
  assert.equal(sessions.length, 1, "健康会话应复用");
  // 两次 send 复用同一 JWT(未过 50 分钟)
  assert.equal(
    sessions[0]!.requests[0]!.headers["authorization"],
    sessions[0]!.requests[1]!.headers["authorization"],
  );

  sessions[0]!.emit("goaway");
  const third = client.send({ deviceToken: "c", payload: {} });
  assert.equal(sessions.length, 2, "GOAWAY 后应重建连接");
  respond(sessions[1]!.requests[0]!.stream, 200);
  await third;

  sessions[1]!.closed = true;
  const fourth = client.send({ deviceToken: "d", payload: {} });
  assert.equal(sessions.length, 3, "已关闭会话不应复用");
  respond(sessions[2]!.requests[0]!.stream, 200);
  await fourth;
});

test("stream error 时 send 拒绝", async () => {
  const { client, sessions } = makeClient();
  const promise = client.send({ deviceToken: "x", payload: {} });
  sessions[0]!.requests[0]!.stream.emit("error", new Error("ECONNRESET"));
  await assert.rejects(promise, /ECONNRESET/);
});
