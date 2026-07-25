// APNs 发送端:token-based(.p8)认证 + node:http2。
// http2 会话通过 connectFn 注入,测试用替身,永不打真网。

import { createSign } from "node:crypto";
import { connect } from "node:http2";

export type ApnsEnvironment = "production" | "sandbox";

export const APNS_AUTHORITIES: Record<ApnsEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

// Apple 要求 provider token 签发后 20–60 分钟内有效;50 分钟重签留出时钟偏差余量
const JWT_REFRESH_MS = 50 * 60 * 1000;

export interface ApnsJwtSignerOptions {
  teamId: string;
  keyId: string;
  /** .p8 内容(PKCS#8 PEM,P-256) */
  privateKeyPem: string;
  now?: () => number;
}

export class ApnsJwtSigner {
  #teamId: string;
  #keyId: string;
  #privateKeyPem: string;
  #now: () => number;
  #token: string | null = null;
  #issuedAtMs = 0;

  constructor(options: ApnsJwtSignerOptions) {
    this.#teamId = options.teamId;
    this.#keyId = options.keyId;
    this.#privateKeyPem = options.privateKeyPem;
    this.#now = options.now ?? Date.now;
  }

  token(): string {
    const nowMs = this.#now();
    if (this.#token !== null && nowMs - this.#issuedAtMs < JWT_REFRESH_MS) {
      return this.#token;
    }
    const header = base64UrlJson({ alg: "ES256", kid: this.#keyId });
    const claims = base64UrlJson({ iss: this.#teamId, iat: Math.floor(nowMs / 1000) });
    const signingInput = `${header}.${claims}`;
    // APNs 要求 JOSE 原始 r‖s 签名(64 字节),不是 DER
    const signature = createSign("SHA256")
      .update(signingInput)
      .sign({ key: this.#privateKeyPem, dsaEncoding: "ieee-p1363" });
    this.#token = `${signingInput}.${signature.toString("base64url")}`;
    this.#issuedAtMs = nowMs;
    return this.#token;
  }
}

function base64UrlJson(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

// http2 替身只需实现这两个最小接口;node:http2 的真会话天然满足
export interface ApnsHttp2Stream {
  setEncoding(encoding: string): unknown;
  on(event: "response", listener: (headers: Record<string, string | string[] | number | undefined>) => void): unknown;
  on(event: "data", listener: (chunk: string) => void): unknown;
  on(event: "end", listener: () => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
  end(data: string): unknown;
}

export interface ApnsHttp2Session {
  request(headers: Record<string, string>): ApnsHttp2Stream;
  on(event: "goaway" | "close" | "error", listener: () => void): unknown;
  close(): unknown;
  readonly closed: boolean;
  readonly destroyed: boolean;
}

export type ApnsPushType = "alert" | "background";

export interface ApnsClientOptions {
  teamId: string;
  keyId: string;
  bundleId: string;
  privateKeyPem: string;
  environment: ApnsEnvironment;
  /** 测试注入替身;默认 http2.connect */
  connectFn?: (authority: string) => ApnsHttp2Session;
  now?: () => number;
}

export interface ApnsSendRequest {
  deviceToken: string;
  payload: Record<string, unknown>;
  /** 默认 "alert" */
  pushType?: ApnsPushType;
  /** 默认 10 */
  priority?: number;
  /** 默认 bundleId */
  topic?: string;
  collapseId?: string;
}

export interface ApnsSendResult {
  status: number;
  apnsId?: string;
  reason?: string;
  /** 410 Unregistered / BadDeviceToken:上层应据此剔除该 token */
  tokenGone: boolean;
}

export class ApnsClient {
  #bundleId: string;
  #environment: ApnsEnvironment;
  #connectFn: (authority: string) => ApnsHttp2Session;
  #signer: ApnsJwtSigner;
  #session: ApnsHttp2Session | null = null;

  constructor(options: ApnsClientOptions) {
    this.#bundleId = options.bundleId;
    this.#environment = options.environment;
    this.#connectFn = options.connectFn ?? ((authority: string) => connect(authority));
    this.#signer = new ApnsJwtSigner({
      teamId: options.teamId,
      keyId: options.keyId,
      privateKeyPem: options.privateKeyPem,
      now: options.now ?? Date.now,
    });
  }

  async send(request: ApnsSendRequest): Promise<ApnsSendResult> {
    const session = this.#ensureSession();
    const headers: Record<string, string> = {
      ":method": "POST",
      ":path": `/3/device/${request.deviceToken}`,
      authorization: `bearer ${this.#signer.token()}`,
      "apns-topic": request.topic ?? this.#bundleId,
      "apns-push-type": request.pushType ?? "alert",
      "apns-priority": String(request.priority ?? 10),
    };
    if (request.collapseId !== undefined) headers["apns-collapse-id"] = request.collapseId;

    return await new Promise<ApnsSendResult>((resolve, reject) => {
      const stream = session.request(headers);
      let status = 0;
      let apnsId: string | undefined;
      let body = "";
      stream.setEncoding("utf8");
      stream.on("response", (responseHeaders) => {
        status = Number(responseHeaders[":status"] ?? 0);
        const id = responseHeaders["apns-id"];
        if (typeof id === "string") apnsId = id;
      });
      stream.on("data", (chunk) => {
        body += chunk;
      });
      stream.on("error", (error) => reject(error));
      stream.on("end", () => {
        let reason: string | undefined;
        if (body !== "") {
          try {
            const parsed = JSON.parse(body) as { reason?: unknown };
            if (typeof parsed.reason === "string") reason = parsed.reason;
          } catch {
            // 非 JSON body 时只报 status
          }
        }
        resolve({
          status,
          tokenGone: status === 410 || reason === "BadDeviceToken" || reason === "Unregistered",
          ...(apnsId !== undefined && { apnsId }),
          ...(reason !== undefined && { reason }),
        });
      });
      stream.end(JSON.stringify(request.payload));
    });
  }

  close(): void {
    if (this.#session !== null) {
      this.#session.close();
      this.#session = null;
    }
  }

  /** 连接懒建;GOAWAY/close/error 后丢弃缓存,下一次 send 自动重建 */
  #ensureSession(): ApnsHttp2Session {
    const existing = this.#session;
    if (existing !== null && !existing.closed && !existing.destroyed) return existing;
    const session = this.#connectFn(APNS_AUTHORITIES[this.#environment]);
    const forget = (): void => {
      if (this.#session === session) this.#session = null;
    };
    session.on("goaway", forget);
    session.on("close", forget);
    session.on("error", forget);
    this.#session = session;
    return session;
  }
}

export function createApnsClient(options: ApnsClientOptions): ApnsClient {
  return new ApnsClient(options);
}
