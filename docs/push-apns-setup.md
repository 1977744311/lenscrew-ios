# APNs 推送配置

SSE 在 iOS 后台不存活。审批到达与轮次完成要在 App 退后台、甚至锁屏时唤起手机，靠的是 APNs 推送：bridge 直连 Apple（token-based `.p8` 认证，JWT over HTTP/2），不经任何第三方推送服务。

推送是**可选**的：`~/.lenscrew/apns.json` 缺失时，bridge 启动打一行「APNs 未配置」后照常跑，只是没有后台通知。

## 会推送什么

| 事件 | 表现 |
|---|---|
| 审批请求 | time-sensitive 通知，带**「允许一次」/「拒绝」**两个按钮，锁屏长按即可直接裁决，不必进 App；同一审批只推一次 |
| 轮次完成 | 普通通知，标题为会话名，正文区分完成 / 中断 / 达到 token 上限 / 被拒绝 / 失败 |
| bridge 致命错误 | 普通通知 |

每台手机可在 App 内分别开关「审批」与「轮次完成」两类提醒。

## 前提

- **付费 Apple Developer Program 会籍**：建 APNs Auth Key 与真机推送签名都需要。免费个人 Team 无法启用推送能力（不影响 LensCrew 其余全部功能；免费账号签名报错的处理见 [glasses-self-build.md](glasses-self-build.md) 的签名一节）
- App 已按你自己的 Bundle ID 自建装机

## 步骤

### ① Apple 后台建 APNs Auth Key（.p8）

1. [developer.apple.com](https://developer.apple.com/account) → **Certificates, Identifiers & Profiles → Keys** → 「+」
2. 勾选 **Apple Push Notifications service (APNs)**，命名后注册
3. **下载 `.p8` 文件**（形如 `AuthKey_XXXXXXXXXX.p8`）——只有这一次下载机会，妥善保存
4. 记下页面上的 **Key ID**（10 位，如 `KEYID12345`）
5. **Team ID** 在 Account → Membership details（10 位，如 `TEAMID1234`）

一把 Auth Key 对整个 Team 的所有 App 有效，无需为 LensCrew 单独建。

### ② 写 ~/.lenscrew/apns.json

把 `.p8` 放进状态目录，再照 `bridge/apns.example.json` 写配置：

```bash
cp AuthKey_XXXXXXXXXX.p8 ~/.lenscrew/
cp bridge/apns.example.json ~/.lenscrew/apns.json
chmod 600 ~/.lenscrew/apns.json ~/.lenscrew/AuthKey_XXXXXXXXXX.p8
```

```json
{
  "teamId": "TEAMID1234",
  "keyId": "KEYID12345",
  "bundleId": "dev.steven.LensCrew",
  "privateKeyPath": "AuthKey_XXXXXXXXXX.p8"
}
```

- **`bundleId` 必须等于你自建 App 实际签名的 Bundle ID**（自建时改过就填改后的），不一致 Apple 会拒收
- `privateKeyPath` 相对状态目录解析，也可给绝对路径；不想留文件可改用 `"privateKey"` 键直接内联 PEM 文本
- 用了 `--state-dir` / `LENSCREW_STATE_DIR` 的话，`apns.json` 跟着放到那个目录
- 缺文件、缺字段或 JSON 损坏时推送整体禁用，bridge 不会因此启动失败

### ③ 重启 bridge、手机注册

重启 `lenscrew up`，启动日志出现：

```
  APNs 已就绪,审批与轮次完成将推送到已注册手机
```

手机 App 连上后授权通知，device token 自动上报，bridge 记入 `~/.lenscrew/push-tokens.json`（运行时文件，无需手工编辑）。

## development 与 production

- Xcode 直装真机的构建走 **development** 环境（对应 Apple 的 sandbox 推送网关）；工程的 `aps-environment` entitlement 即 development。LensCrew 的源码自建分发模式下，你通常始终在这个环境
- 若某台手机装的是 TestFlight / 正式分发构建，则是 **production** 环境
- **无需手工配置**：每台手机上报 token 时自带环境标记，bridge 按 token 分别走 sandbox 或 production 网关，同一把 `.p8` 两个环境通用

## 自测

**模拟器**（不经 Apple，验证通知呈现与按钮动作）：

存一份 `approval.apns`：

```json
{
  "aps": {
    "alert": { "title": "运行 shell 命令", "body": "npm test" },
    "sound": "default",
    "thread-id": "sess-demo",
    "interruption-level": "time-sensitive",
    "category": "LENSCREW_APPROVAL"
  },
  "lenscrew": {
    "kind": "approval",
    "sessionId": "sess-demo",
    "approvalId": "appr-demo",
    "onceAllowOptionId": "opt-allow-once",
    "denyOptionId": "opt-deny"
  }
}
```

```bash
xcrun simctl push booted dev.steven.LensCrew approval.apns   # bundleId 换成你自己的
```

通知应带「允许一次 / 拒绝」按钮（category `LENSCREW_APPROVAL`；轮次通知是 `LENSCREW_TURN`）。

**真机全链路**：需付费 Team 签名装机。App 退后台后，在 Mac 上让 agent 触发一次需要审批的操作，锁屏应弹出可操作通知；点「允许一次」，Mac 侧命令应继续执行。

## 排查

- 启动日志停在「APNs 未配置」：`apns.json` 路径、JSON 语法、四个字段逐一核对（`privateKeyPath` 相对状态目录）
- 日志出现「推送失败」：多为 `bundleId` 与实际签名不符，或 Key 被吊销
- 真机收不到：确认系统设置里允许了通知、构建带 push entitlement（付费 Team）、手机在 App 内开着对应类别的提醒
