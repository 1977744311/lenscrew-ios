# 自架 relay 中继

手机和 Mac 不在同一局域网时，流量经自架 relay 中转。relay 是零状态哑管道：按房间转发密文帧、不缓冲、不鉴权、不落盘——安全性质全部由端到端加密承担（见 [remote-access-security.md](remote-access-security.md)），所以它可以放心跑在最便宜的 VPS 上。

## 起服务

VPS 上装 Node ≥ 22.18，clone 本仓库即可（relay 零运行时依赖，无需 `npm install`）：

```bash
git clone https://github.com/<你的账号>/lenscrew-ios /opt/lenscrew
node /opt/lenscrew/bridge/bin/lenscrew.ts relay --host 127.0.0.1 --port 4370
```

`lenscrew relay` 只说 HTTP；**TLS 交给反向代理**。生产上建议只监听回环（如上），由反代对外提供 443。

systemd 常驻示例（`/etc/systemd/system/lenscrew-relay.service`）：

```ini
[Unit]
Description=LensCrew relay
After=network-online.target

[Service]
ExecStart=/usr/bin/node /opt/lenscrew/bridge/bin/lenscrew.ts relay --host 127.0.0.1 --port 4370
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
```

## 反向代理：必须放行 SSE / 长连接

下行通道是 SSE（`text/event-stream`）长连接，反代**不能缓冲响应、不能过早超时**。relay 自带每 15 秒一次的心跳注释行，用于穿透空闲超时。

**Nginx**（relay 响应已带 `X-Accel-Buffering: no`，以下配置再兜一层底）：

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;
    # ssl_certificate / ssl_certificate_key 按你的证书来

    location / {
        proxy_pass http://127.0.0.1:4370;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 1h;
    }
}
```

**Caddy**（自动 HTTPS，SSE 默认即流式转发）：

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:4370 {
        flush_interval -1
    }
}
```

**Traefik**：默认可用；若配置过响应缓冲，给该路由设 `flushInterval` 为负值（立即刷出）。

## 备选：不架 VPS

- **Cloudflare Tunnel**：`cloudflared tunnel --url http://127.0.0.1:4370` 起临时隧道，或建常驻 tunnel 绑自己的域名。Cloudflare 代理支持 SSE；免费档即可
- **Tailscale**：如果手机和 Mac 都在同一 tailnet，**根本不需要 relay**——`lenscrew up --host <Mac 的 Tailscale IP>` 让手机按局域网直连方式走加密隧道即可。relay 只在你不想在手机上装 VPN 时才有必要（LensCrew 远程接入的初衷正是彻底脱离 VPN）

## 对接 bridge

Mac 上带 `--relay` 起 bridge：

```bash
cd bridge && node bin/lenscrew.ts up --relay https://relay.example.com
```

- 启动日志会打出本机房间地址：`<relay>/v1/rooms/<macDeviceId>`（房间按 macDeviceId 划分）
- 此后打印的配对二维码内含 relay 地址，手机扫码后自动获得中继路径
- `--relay` 与 `--host` 可同时给：手机**直连优先、失败回退中继**，两条路径同一套 E2EE 协议

## 健康检查

```bash
curl https://relay.example.com/health
# {"ok":true}
```

## 端点与内建限制（运维参考）

| 项 | 值 |
|---|---|
| `GET /health` | 存活探针，返回 `{"ok":true}` |
| `GET /v1/rooms/{roomId}/stream?role=mac\|phone` | SSE 下行；同房间同角色只保留最新连接，旧连接收到 `evicted` 后被断开 |
| `POST /v1/rooms/{roomId}/send?role=mac\|phone` | 上行单帧；对端在线返回 `{"delivered":true}`，不在线返回 202 `{"delivered":false}`（**不缓冲补发**） |
| roomId 格式 | `[A-Za-z0-9-]{8,64}` |
| 单帧上限 | 1 MiB |
| 限流（按来源 IP，固定窗口） | 全部 HTTP 120 次/分钟；新建 SSE 60 次/分钟 |
| 心跳 | 每 15 秒一行 SSE 注释 `: ping` |
| 日志 | 只记房间号 SHA-256 前 8 位与角色，无内容、无明文 |

relay 无鉴权是设计使然：它转发的只是密文，伪造与窃听都过不了 E2EE。但仍建议上 TLS（保护流量元数据）、防火墙只开 443。
