# LensCrew

把本机的 Codex、Claude Code、Cursor Agent 三个编码 agent 收进一个指挥台：手机是完整的指挥台，Apple Watch 与 Meta Ray-Ban Display 眼镜是可选延伸——抬眼看流水、抬手批工具调用。

本地优先：agent 运行时、仓库和工作区操作全部留在 Mac，手机 / 手表 / 眼镜只是远端控制面。

```
┌──────────────┐   SSE 下行 / POST 上行   ┌──────────────────┐   stdio   ┌──────────────────┐
│  iOS App     │ ◄──────────────────────► │  lenscrew bridge │ ◄───────► │ codex app-server │
│  ├ 手机 UI    │                          │  ├ 三个 adapter   │           │ claude -p stream │
│  └ 眼镜 (DAT) │                          │  └ 会话事件总线    │           │ cursor-agent acp │
└──────────────┘                          └──────────────────┘           └──────────────────┘
```

## 能力

- **统一契约**：codex app-server / claude stream-json / cursor-agent ACP 三条链路归一为同一套会话与审批事件，TS 与 Swift 双语 fixture 锁死线上格式（`protocol/fixtures/`，两侧测试消费同一份 JSON）
- **手机端六屏 UI**：指挥台 / 会话流水 / 审批 / 新会话 / 眼镜 / 设置，不依赖眼镜即完整可用
- **会话模式**：新建会话按 agent 选档（codex：只读 / 每步审批 / 按需审批 / 完全放行；claude：plan / default / acceptEdits / bypass；cursor：agent / plan / ask，运行时自陈），会话中也能在输入栏的模式 chip 上随时切换——codex 走 turn 级 policy 覆盖（下一轮生效），claude 走 `set_permission_mode` 控制请求，cursor 走 ACP `session/set_mode`，全部实测验证
- **模型与推理档**：模型清单由各运行时自陈（codex `model/list`、claude init 自报、cursor `session/new` 自报），新建会话可选，会话页头部也能随时换；codex 的模型另带推理档（minimal / low / medium / high 随模型自陈），新建与会话中都可调
- **会话韧性**：bridge 把活跃会话的路由表落盘（`~/.lenscrew/sessions.json`），重启后自动续接原生会话——codex 全量回放历史流水，claude / cursor 上下文延续；App 冷接入用 `fromSeq=1` 补拉全部留存事件。死会话（已结束 / 出错）在首页长按或会话页一键「续接」，原生会话都在各 CLI 自己的状态目录里，不会真丢
- **眼镜端四屏**：会话列表 / 流水 / 块详情 / 审批卡，600×600，在 DAT 0.8.0 硬约束下做整屏替换 + tap-only + 分页
- **Apple Watch**：腕上审批（允许一次 / 本会话 / 拒绝，可中断）、会话一瞥、听写追加指令、Smart Stack 小组件与七个表盘复杂功能模块（覆盖圆形 / 边角 / 单行 / 矩形全部槽位）；经 WatchConnectivity 由 iPhone 中转，手表不直连 bridge / relay，不持有任何密钥
- **Codex 账号额度**：bridge 经 `account/rateLimits/read` + `updated` 采集，闲时由探针每 30 分钟校准一次；手机指挥台按窗口给进度条与重置时间，额度也随快照进手表表盘。Claude / Cursor 无程序化额度通道（见 Roadmap）
- **远程接入（脱离 VPN）**：二维码配对 + 端到端加密 + 自架 relay 中继；局域网直连与中继同协议，直连优先、失败回退中继
- **APNs 推送**：bridge 直连 Apple（token-based .p8，JWT over HTTP/2）；审批到达与轮次完成即使 App 在后台 SSE 已断也能唤起；审批推送带「允许一次 / 拒绝」可操作按钮，锁屏直接裁决
- **多 Mac**：手机存多台主机（每台一条 Keychain 口令与公钥记录），设置页切换，会话列表标注归属；支持同时保持多条连接、跨主机聚合会话与合并审批队列
- **git 操作面板**：会话页一键进入所属仓库——分支 / ahead-behind / stash 一眼可见，暂存区与工作区文件按行看 diff（untracked 也给全新增 diff），暂存 / 取消暂存 / 丢弃、提交、推拉、切换与新建分支、stash 都在手机上完成；pull 恒为 `--ff-only`，收不了的冲突原样透传 git 的话，不在手机上制造复杂状态
- **手机端语音输入**：composer 麦克风一点即听写（Speech framework，语言跟随系统），识别文本实时进草稿、发送仍由发送键决定；手表端的听写追加指令同样可用
- **开源自建分发**：不发 iOS 安装包，源码自建（见[分发模式](#分发模式为什么不发安装包)）

## Roadmap

- 电脑端既有会话的发现与接管：把 Mac 上不经 LensCrew 开的 agent 会话也纳入指挥台——三家历史都在本地（codex `~/.codex/sessions/` rollout、claude `~/.claude/projects/` jsonl、`cursor-agent ls`），bridge 就地枚举出列表，手机上一键续接；codex / cursor 续接自带历史回放，claude 需解析其 jsonl 渲染历史（Cursor IDE 图形界面的聊天存于私有 SQLite，不在此列）
- Claude / Cursor 账号额度：两家目前都没有程序化通道（Claude 的 stream-json 只给 token 用量，Cursor ACP 的 usage_update 是上下文占用而非额度），待上游暴露再接
- 历史分页：codex resume 现在整段回放，超长会话应按页懒加载更早的历史
- 真机验证：眼镜依赖 Meta Wearables Developer Center 注册与固件 / Meta AI App 版本（见 [眼镜自建](docs/glasses-self-build.md)）；手表 app group 与 APNs 推送在真机上需要开发者账号签名

## 快速开始

前置：Mac 上装有 Node ≥ 22.18（bridge 零运行时依赖，直接跑 TS，无需 `npm install`），以及至少一个 agent CLI（`codex` / `claude` / `cursor-agent`）。

**1. 起 bridge：**

```bash
cd bridge && node bin/lenscrew.ts up --host 0.0.0.0
```

默认只监听回环，手机连不上——要连手机得显式给 `--host`（局域网地址或 `0.0.0.0`）或 `--relay`，免得在公共 Wi-Fi 上不知不觉把本机 agent 暴露出去。启动时打印 macDeviceId、身份指纹、访问口令与**终端二维码**；配对窗口开 5 分钟，过期后用 `lenscrew qr` 重开。

日常挂着用建议装成常驻（macOS LaunchAgent，开机自启、崩溃自动拉起、日志落 `~/.lenscrew/logs/bridge.log`）：

```bash
node bin/lenscrew.ts service install --host 0.0.0.0   # 参数与 up 相同；口令自动生成并固定进 plist
node bin/lenscrew.ts service status                   # 查看运行状态
node bin/lenscrew.ts service uninstall                # 停止并卸载
```

常驻模式口令跨重启不变，手机配对一次即可；bridge 重启后活跃会话自动续接。

**2. 自建 iOS App**（本项目不发安装包）：

```bash
brew install xcodegen
xcodegen generate
open LensCrew.xcodeproj
```

Xcode 里选自己的 Team、改 Bundle ID，签名装到 iPhone（iOS 17+）。不配眼镜凭据也能编译运行：模拟器走 Mock 眼镜，手机端六屏全部可用。

**3. 手机配对**：App 内「添加电脑」扫 bridge 打印的二维码，完成端到端加密配对，即可建会话、发消息、批审批。

CLI 全部表面：

```
lenscrew up    [--host 地址] [--port 4311] [--token 口令] [--relay https://…] [--name 设备名] [--state-dir 目录]
lenscrew qr    [--state-dir 目录]     # 向本机运行中的 bridge 重开 5 分钟配对窗口并重打印二维码
lenscrew relay [--host 0.0.0.0] [--port 4370]   # 自架中继服务器
lenscrew service install [up 选项]   # 装成 launchd 常驻：开机自启、崩溃拉起、日志落盘、口令固定
lenscrew service uninstall           # 停止并卸载常驻
lenscrew service status              # 常驻状态（state / pid / 上次退出码）
```

状态目录 `~/.lenscrew`（可用 `LENSCREW_STATE_DIR` 覆盖，权限 0700）：`identity.json`（Ed25519 身份，0600）、`trusted-phones.json`（可信手机公钥）、`apns.json`（用户手工放置，见推送一节）、`push-tokens.json`、`admin.json`、`sessions.json`（活跃会话路由表，重启续接用）与 `logs/`（常驻模式日志）。

## 远程接入（脱离 VPN）

手机不必和 Mac 同一局域网：

- **配对**：扫码即建立信任——二维码内含 Mac 的身份公钥作信任根，配对窗口 5 分钟时效
- **端到端加密**：X25519 密钥协商 + Ed25519 身份签名 + HKDF-SHA256 派生 + 方向隔离的 AES-256-GCM，counter 即 nonce、单调递增防重放
- **自架 relay**：`lenscrew relay` 部署到 VPS，按 macDeviceId 分房间、只转发密文、不缓冲，日志仅打房间号哈希前 8 位——relay 被攻破也只见密文
- **路径选择**：局域网直连与 relay 中继同协议，直连优先、失败回退中继

协议细节与威胁模型见 [docs/remote-access-security.md](docs/remote-access-security.md)，relay 部署见 [docs/self-hosting-relay.md](docs/self-hosting-relay.md)。

## 推送（APNs）

SSE 在 iOS 后台不存活，审批与完成通知靠推送唤起。bridge 直连 Apple（token-based `.p8` 认证），把 Apple Developer 后台建的 Auth Key 信息写进 `~/.lenscrew/apns.json` 即启用；缺文件则推送整体禁用、bridge 照常跑。审批推送带「允许一次 / 拒绝」按钮，锁屏直接裁决。配置步骤见 [docs/push-apns-setup.md](docs/push-apns-setup.md)。

## 多 Mac

手机可保存多台 Mac：每台一条独立的 Keychain 记录（口令 + 身份公钥），设置页一键切换，会话列表标注每条会话归属哪台主机。进阶用法：同时保持多条连接，跨主机聚合会话列表与合并审批队列——多台机器上的 agent 在一个屏幕里批。

## Apple Watch

腕上审批器 + 状态一瞥，四屏：审批卡（允许一次 / 本会话 / 拒绝，可中断，选项随 agent 自陈能力动态生成）、会话列表、会话详情（听写追加指令）、Smart Stack 小组件。连接经 WatchConnectivity 由 iPhone 中转：手表只依赖协议层，不直连 bridge / relay，不持有任何密钥。手表 app 随 iOS app 一起构建（Embed Watch Content），无需单独安装。

**表盘复杂功能**：七个模块——LensCrew 一瞥、待审批、运行中会话、Codex 额度环、额度详情、任务 + 额度组合卡、已连主机——覆盖圆形 / 边角 / 单行 / 矩形全部槽位（矩形槽见于 Modular / Infograph Modular / Modular Ultra 等表盘），在表盘编辑里添加，点按直达审批队列或 App，去色表盘下由系统统一着色。数据由 iPhone 推送：常态走 applicationContext，表盘数字靠 `transferCurrentComplicationUserInfo` 后台唤起刷新——系统给它每天约 50 次预算，桥接侧按「腕上可见数字真变了才花、除新审批外至少间隔 15 分钟」花费。表盘定位是分钟级一瞥，审批的实时性仍以推送通知与打开 App 为准。

## 眼镜自建

Meta Ray-Ban Display 眼镜功能是可选延伸，使用者自行注册 Meta 开发者并自打包：

1. Meta AI App 打开开发者模式（设置 → 应用信息 → 版本号连点 5 次）
2. 确认眼镜固件与 Meta AI App 版本满足 DAT SDK 要求
3. 到 [Meta Wearables Developer Center](https://wearables.developer.meta.com/) 注册、建 Project，拿 iOS 集成的 MetaAppID 与 ClientToken
4. 复制 `App/Support/Secrets.example.xcconfig` 为 `Secrets.xcconfig`（已 gitignore），填入两个值
5. Xcode 选个人 Team、改 Bundle ID，真机签名运行

**没有 MWDAT 配置也能编译运行**：模拟器走 Mock，真机上眼镜功能休眠，手机端不受影响。DAT SDK 是公开 SPM 依赖（`facebook/meta-wearables-dat-ios`），无需私有源。完整步骤见 [docs/glasses-self-build.md](docs/glasses-self-build.md)。

## 运行时接口矩阵

三个 agent 的程序化接口差异很大。下表基于对表头所列版本实际行为的验证，而非官方文档转述；上游版本更新后可能失准，欢迎提 issue 勘误。

| | Codex 0.144.4 | Claude Code 2.1.215 | Cursor 2026.07.23 |
|---|---|---|---|
| 驱动方式 | `codex app-server`，JSON-RPC over stdio | `claude -p --input-format stream-json --output-format stream-json`，NDJSON | `cursor-agent acp`，ACP over stdio |
| 协议自描述 | 有 `generate-ts` / `generate-json-schema`，但和线上不完全一致 | 无 | 遵循 [ACP](https://agentclientprotocol.com)，实测有三处出入 |
| 审批通道 | 服务端发 `item/*/requestApproval` 请求等客户端应答 | `--permission-prompt-tool stdio` 开启 control protocol | ACP `session/request_permission` |
| 会话条目 | 18 类 `ThreadItem` | Anthropic content block | ACP session update |

三处经验证与文档或生成物不一致的行为，按文档实现会踩坑：

**Cursor 的 `-p` 模式没有审批通道。** 需要审批的 shell 调用不会向客户端发请求，而是直接以 `tool_call/completed` 且 `result.rejected` 收场。要审批必须走 ACP。这正是契约把 `capabilities` 做成 adapter 运行时自陈、而不是按 agent 种类硬编码的原因。

**Codex 的 v2 审批不吃 `ReviewDecision`。** `generate-ts` 导出的 `ReviewDecision`（`approved` / `denied` …）只属于旧版通道；v2 要的是 `accept` / `acceptForSession` / `decline` / `cancel`。发错不报 JSON-RPC 错误，命令静默以 `declined` 收场。另外线上的审批请求带 `availableDecisions` 字段，生成物里没有，它才是本次可用裁决的权威来源。

**Claude 的 `--permission-prompt-tool` 只是从 `--help` 里隐藏了。** 它仍然存在，且 `stdio` 是保留值，正是审批通道的开关；不带它，headless 会话会静默拒绝每一个工具调用。传别的字符串会被当成 MCP 工具名去查然后退出。

## 眼镜端约束

DAT 0.8.0 给的余地很小，这些是硬约束，不是设计偏好：

- 600×600，整屏替换式更新，无局部刷新
- 文字只有 3 字号 × 2 色，没有字体度量 API
- 只能垂直滚动，且**没有滚动回调、没有滚动位置查询**
- 输入只有 tap，没有文本输入、没有长按
- 20 秒变暗 / 25 秒休眠（不结束会话）

因此眼镜端不依赖滚动：`TranscriptPaginator` 把会话流水切成确定的页序列，用户按翻页按钮走。分页从头贪心装页，保证末尾追加内容不会让用户正在看的历史页重新排版跳走。

## 仓库结构

```
protocol/fixtures/     TS 与 Swift 共用的黄金样本，两侧测试都消费它
bridge/                Mac bridge（Node，零运行时依赖）
  src/protocol/        统一契约（线上格式的判定权在这里）
  src/adapters/        三个运行时的 adapter，差异只允许存在于此
  src/git/             git 操作面板的执行侧（execFile 真 git，无 shell 展开）
  src/secure/          E2EE：握手状态机与密码学纯函数
  src/relay/           自架中继的服务端与 bridge 侧客户端
  src/push/            APNs：配置、HTTP/2 客户端、推送决策
  src/qr/              终端二维码渲染
  src/state/           ~/.lenscrew 状态目录：身份密钥、手机信任表、会话路由表
  src/service/         launchd 常驻安装器（service install/uninstall/status）
Sources/               LensCrewKit（Swift 6，库层零第三方依赖）
  AgentProtocol/       bridge 契约的 Swift 同构镜像
  BridgeLink/          与 bridge 的连接、SSE 解码
  GlassesKit/          Meta Wearables DAT 的唯一抽象边界
  GlassRenderer/       布局树、流水分页、四种眼镜屏
  LensCrewCore/        客户端会话状态机
App/                   iOS App target（真实 SDK 绑定收敛在 Adapters/）
```

## 开发与测试

```bash
swift test                                    # 库层，不需要眼镜也不需要 SDK
cd bridge && node --test 'test/**/*.test.ts'  # bridge，Node 22.18+ 原生跑 TS
cd bridge && npx tsc --noEmit                 # 类型检查（运行时靠类型擦除，不做构建）
```

契约同步靠 `protocol/fixtures/`：同一份 JSON 被两种语言的测试同时消费，任一侧改了线上格式而没同步另一侧，两边都会红。端到端链路由 `Tests/LensCrewCoreTests/EndToEndTests.swift` 覆盖——真起 bridge 进程，一路验到眼镜屏上出现审批卡。

贡献流程与规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 安全与隐私

- **口令只防误连**，不是安全边界；端到端加密才是安全边界
- **E2EE**：身份签名 + 全字段绑定的握手 transcript 防降级与中间人；方向隔离密钥 + 单调 counter 防重放
- **relay 零知识**：只见密文与房间号，日志只记房间号哈希前 8 位，不缓冲任何帧
- **密钥只落两处**：iOS Keychain（`WhenUnlockedThisDeviceOnly`）与 Mac `~/.lenscrew`（目录 0700、文件 0600），绝不入库
- **本地优先**：代码、仓库、agent 进程全在 Mac，云端至多经过一台只见密文的自架 relay

完整威胁模型见 [docs/remote-access-security.md](docs/remote-access-security.md)。

## 分发模式（为什么不发安装包）

LensCrew 不分发 iOS 安装包（IPA / TestFlight），只做源码自建：

- 遵守 Apple Developer Program 条款——个人开发者签名的构建不适合对外再分发
- Meta Wearables DAT 处于 developer preview，未发布应用只能自建或走邀请制 release channel

这与 turbometa、remodex 等项目的源码分发模式一致：clone 仓库、填自己的凭据、Xcode 个人签名装机。眼镜凭据（MWDAT）与推送密钥（APNs）都由使用者自持，模板见 `App/Support/Secrets.example.xcconfig` 与 `bridge/apns.example.json`。

## 许可证与致谢

[MIT](LICENSE)。

架构上参考了 [Remodex](https://github.com/Emanuele-web04/remodex)（Apache-2.0）的本地优先 bridge 思路；分发模式参考了 turbometa 的源码自建实践。LensCrew 是独立实现，不使用两者的名称与品牌。
