# LensCrew

把本机的 Codex、Claude Code、Cursor Agent 三个编码 agent 收进一个指挥台：手机负责下指令和打字，Meta Ray-Ban Display 眼镜负责抬眼看流水、抬手批工具调用。

agent 运行时、仓库和工作区操作全部留在 Mac，手机和眼镜只是远端控制面。

```
┌──────────────┐   SSE 下行 / POST 上行   ┌──────────────────┐   stdio   ┌──────────────────┐
│  iOS App     │ ◄──────────────────────► │  lenscrew bridge │ ◄───────► │ codex app-server │
│  ├ 手机 UI    │                          │  ├ 三个 adapter   │           │ claude -p stream │
│  └ 眼镜 (DAT) │                          │  └ 会话事件总线    │           │ cursor-agent acp │
└──────────────┘                          └──────────────────┘           └──────────────────┘
```

## 运行时接口矩阵

三个 agent 的程序化接口差异很大，下表是 2026-07-25 在本机实测的结论，不是照文档抄的。

| | Codex 0.144.4 | Claude Code 2.1.215 | Cursor 2026.07.23 |
|---|---|---|---|
| 驱动方式 | `codex app-server`，JSON-RPC over stdio | `claude -p --input-format stream-json --output-format stream-json`，NDJSON | `cursor-agent acp`，ACP over stdio |
| 协议自描述 | 有 `generate-ts` / `generate-json-schema`，但和线上不完全一致 | 无 | 遵循 [ACP](https://agentclientprotocol.com)，实测有三处出入 |
| 审批通道 | 服务端发 `item/*/requestApproval` 请求等客户端应答 | `--permission-prompt-tool stdio` 开启 control protocol | ACP `session/request_permission` |
| 会话条目 | 18 类 `ThreadItem` | Anthropic content block | ACP session update |

三个实测发现，都是照文档或生成物写会踩的坑：

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
Sources/               LensCrewKit（Swift 6，库层零第三方依赖）
  AgentProtocol/       bridge 契约的 Swift 同构镜像
  BridgeLink/          与 bridge 的连接、SSE 解码
  GlassesKit/          Meta Wearables DAT 的唯一抽象边界
  GlassRenderer/       布局树、流水分页、四种眼镜屏
  LensCrewCore/        客户端会话状态机
App/                   iOS App target（真实 SDK 绑定收敛在 Adapters/）
```

## 开发

```bash
swift test                                    # 库层，不需要眼镜也不需要 SDK
cd bridge && node --test 'test/**/*.test.ts'  # bridge，Node 22.18+ 原生跑 TS
cd bridge && npx tsc --noEmit                 # 类型检查（运行时靠类型擦除，不做构建）
```

跑起 bridge：

```bash
cd bridge && node bin/lenscrew.ts up --host 0.0.0.0
```

默认只监听回环，手机连不上——要连手机得显式给 `--host`，免得在公共 Wi-Fi 上不知不觉把本机 agent 暴露出去。

契约同步靠 `protocol/fixtures/`：同一份 JSON 被两种语言的测试同时消费，任一侧改了线上格式而没同步另一侧，两边都会红。

## 现状

M0 已跑通端到端：`lenscrew up` 起 bridge，手机连上去建真实 Cursor 会话、发消息、收到回复，全程走 HTTP + SSE。眼镜链路由 `Tests/LensCrewCoreTests/EndToEndTests.swift` 覆盖——真起 bridge 进程，一路验到眼镜屏上出现审批卡。

已完成：统一契约（TS + Swift 两侧都消费同一份 fixture）、三个运行时的 adapter（各自带实测录制的 fixture）、bridge 的会话总线与 SSE 传输、CLI、眼镜端渲染与导航（分页、审批卡、稳定性保证）、客户端会话状态机（断连补齐与断档检测）、iOS App（连接配置、会话列表、流水、审批、发消息，带真实 MWDAT 编译通过）。

未完成：端到端加密与二维码配对（现在只是局域网直连 + 防误连口令）、git 操作面板、语音输入、眼镜真机验证。真机验证依赖 Meta Wearables Developer Center 注册、Meta AI app v272+、眼镜固件 V127+。

## 参考

架构上参考了 [Remodex](https://github.com/Emanuele-web04/remodex)（Apache-2.0）的本地优先 bridge 思路。LensCrew 是独立实现，不使用其名称与品牌。
