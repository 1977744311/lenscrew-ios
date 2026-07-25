# 远程接入：威胁模型与协议细节

本文描述手机 ↔ Mac 之间远程通道的安全设计。实现在 `bridge/src/secure/`（TS）与 iOS 侧的同构镜像，跨语言一致性由 `protocol/fixtures/e2ee-handshake.json` 锁死——对固定输入，两侧的派生 / 签名 / 封装逐字节相同。

## 安全边界

| 机制 | 作用 | 是不是安全边界 |
|---|---|---|
| 访问口令（`--token`） | 防误连：挡住局域网里无意撞上端口的客户端 | **不是** |
| 端到端加密（E2EE） | 机密性、完整性、身份认证、防重放 | **是** |
| relay | 只搬运密文的哑管道 | 无需信任 |

口令随 bridge 启动打印、可被局域网观察者拿到，它的职责只是防误连。所有跨设备的安全性质由 E2EE 承担：**relay、Wi-Fi、中间盒子全部按敌手对待**。

## 角色与密钥材料

| 密钥 | 算法 | 生命周期 | 存放 |
|---|---|---|---|
| Mac 身份密钥 | Ed25519 | 终身（首启生成） | `~/.lenscrew/identity.json`（0600，目录 0700） |
| 手机身份密钥 | Ed25519 | 终身（首用生成） | iOS Keychain（`WhenUnlockedThisDeviceOnly`） |
| 临时密钥 | X25519 | 单次握手 | 仅内存 |
| 会话密钥（双向各一把） | AES-256 | 单个 keyEpoch | 仅内存 |

Mac 记录可信手机于 `~/.lenscrew/trusted-phones.json`（phoneDeviceId → 手机身份公钥）；手机把每台 Mac 的身份公钥与口令存进 Keychain（每主机独立记录）。

## 配对：TOFU-by-QR

配对采用「扫码即信任」（TOFU，trust on first use），信任根通过二维码这条带外信道传递：

- 二维码 payload：`{ v: 1, kind: "lenscrew-pair", macDeviceId, macIdentityPublicKey, displayName, expiresAtMs, relay?, lan?: { host, port } }`。**没有 pairing secret**——手机对 Mac 的信任来自码里的 `macIdentityPublicKey`（能看到你屏幕/终端的人本来就赢了）；Mac 对手机的信任来自「配对窗口内完成握手」这一事实
- 配对窗口 **5 分钟**：bridge 启动即开，之后用 `lenscrew qr` 重开（它通过 `admin.json` 里的回环管理口令调 `POST /admin/pairing`，该文件 0600、接口只在本机可达）
- 窗口关闭后，`qr_bootstrap` 模式的握手一律被拒（`pairing_expired`）；已在信任表里的手机走 `trusted_reconnect`，不受窗口限制
- 人眼核对：bridge 启动时打印**身份指纹**（身份公钥 SHA-256 的前 16 位 hex），手机端配对完成后可对照
- 同一 `phoneDeviceId` 换了身份公钥再来，即使窗口开着也拒绝（`phone_identity_changed`），防止窗口期劫持已有信任关系

## 握手协议

协议标签 `lenscrew-e2ee-v1`，版本 1。每台手机独立握手：

```
phone → clientHello   （版本、模式、phone 身份公钥、X25519 临时公钥、clientNonce）
mac   → serverHello   （mac 身份公钥、X25519 临时公钥、serverNonce、keyEpoch、
                        pairingExpiresAtMs、mac 对 transcript 的 Ed25519 签名）
phone → clientAuth    （phone 对 transcript‖"client-auth" 的 Ed25519 签名）
mac   → secureReady
之后双向 encryptedEnvelope
```

### transcript：全字段绑定

双方各自重建同一份 **14 字段定序 transcript**，任何一个字段不一致，签名即失效：

```
协议标签 | roomId | protocolVersion | handshakeMode | keyEpoch
| macDeviceId | phoneDeviceId
| mac 身份公钥 | phone 身份公钥 | mac 临时公钥 | phone 临时公钥
| clientNonce | serverNonce | pairingExpiresAtMs
```

- 每字段带 4 字节大端长度前缀再拼接，字段边界无歧义（否则 `("ab","c")` 与 `("a","bc")` 拼出同一串字节，签名能被跨字段挪移）
- `protocolVersion` 与 `handshakeMode` 进 transcript ⇒ **防降级**：敌手改不了版本或把 `trusted_reconnect` 伪装成 `qr_bootstrap`
- 双方临时公钥都进 transcript 且**双向签名**（mac 签 transcript，phone 签 transcript‖长度前缀的 `"client-auth"` 域分隔标签，两个签名不可互相冒用）⇒ **防中间人**：敌手替换任何一侧的临时密钥都会让某个签名验不过
- 握手失败以带码错误帧收场：`protocol_mismatch` / `pairing_expired` / `phone_not_trusted` / `phone_identity_changed` / `invalid_signature` / `decrypt_failed` / `unexpected_frame`

### 密钥派生

X25519 ECDH 得共享秘密后，HKDF-SHA256 派生两把**方向隔离**的 AES-256 密钥：

- salt = SHA-256(transcript)——把整个握手上下文绑进密钥
- info = `lenscrew-e2ee-v1|roomId|macDeviceId|phoneDeviceId|keyEpoch|方向`，方向 ∈ {`phoneToMac`, `macToPhone`}
- `keyEpoch` 每次握手自增（serverHello 携带），重握手即整体换钥；临时密钥单次使用 ⇒ 单个 epoch 的密钥泄露不影响其他 epoch（前向保密以握手为粒度）

## 传输加密

会话数据全部走 AES-256-GCM 信封：

```json
{ "kind": "encryptedEnvelope", "v": 1, "roomId": "…", "keyEpoch": 3,
  "sender": "mac", "counter": 42, "ciphertext": "…", "tag": "…" }
```

- **nonce 12 字节 = [方向字节, 3 字节 0, counter 的 8 字节大端]**（mac=1、phone=2）。方向字节隔开双方 nonce 空间；counter 单调递增保证同 key 下 nonce 永不重复（GCM 硬性要求）
- **counter 即防重放**：接收方要求 counter 严格单调，重放与乱序注入直接失败
- **AAD = `roomId|keyEpoch|sender|counter`**：明文头字段全部绑进认证标签，改任何一个都解密失败——敌手不能把信封改道别的房间、旧 epoch 或对端方向

## relay 在威胁模型中的位置

relay（`bridge/src/relay/relayServer.ts`）是零状态哑管道：按 roomId（= macDeviceId）把帧原文在 mac 与 phone 之间双向转发，**对帧完全不解析**，握手控制帧也从它身上过。

- relay **看得到**：房间号、连接时刻、帧的大小与频率（流量元数据）
- relay **看不到**：任何明文——它被攻破最多丢可用性，拿不到内容，也伪造不了帧（签名与 AEAD 都验不过）
- 日志只记房间号 SHA-256 的前 8 位 hex，日志被第三方采集也无法反查房间
- 不缓冲：对端不在线返回 `delivered: false`，补发由两端重握手/重发解决——relay 上没有任何可窃取的存量数据

局域网直连与 relay 中继跑**同一套 E2EE 协议**，直连优先、失败回退中继；安全性质不随路径变化。

## 密钥存储与吊销

- Mac：`~/.lenscrew`（0700），`identity.json` / `trusted-phones.json` / `admin.json` 均 0600；`LENSCREW_STATE_DIR` 可换目录，权限语义不变
- iOS：口令、Mac 身份公钥、手机身份种子全部进 Keychain，`WhenUnlockedThisDeviceOnly`——不进 iCloud 备份、不跨设备迁移
- 吊销手机：从 Mac 的 `trusted-phones.json` 删掉对应条目（或整文件删除清空信任表），下次握手即拒
- 吊销 Mac：手机设置页删除该主机记录
- Mac 身份需要作废重建：删 `identity.json` 重启 bridge，所有手机需重新扫码配对

## 已知局限（如实声明）

- **配对窗口内的二维码等价于配对权**：能扫到码、又能在 5 分钟内触达 bridge 端点的人可以成为可信手机。缓解：窗口短时效、码只在你自己的终端上显示、配对后核对身份指纹与信任表
- **身份密钥被盗即可冒充**：`identity.json` 或手机 Keychain 失守时，敌手可分别冒充 Mac 或手机。文件权限与 Keychain 策略是缓解不是根治
- **流量元数据不加密**：relay 与网络路径能看到「谁在什么时候说了多大的话」；需要隐藏元数据请自架 relay 并置于自己的信任域
- **epoch 内不换钥**：单个 keyEpoch 期间没有逐消息棘轮；换钥粒度是重握手
