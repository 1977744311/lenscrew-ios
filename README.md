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
| 协议自描述 | ✅ `generate-ts` / `generate-json-schema` 可导出完整协议 | 无 | 遵循 [ACP](https://agentclientprotocol.com) |
| 审批通道 | ✅ 服务端发 `item/*/requestApproval` 请求等客户端应答 | 待验证（`--permission-mode manual` + control protocol） | ✅ ACP `session/request_permission` |
| 会话条目 | 18 类 `ThreadItem` | Anthropic content block | ACP session update |

Cursor 有个反直觉的坑：`cursor-agent -p --output-format stream-json` **没有审批通道**。需要审批的 shell 调用不会向客户端发请求，而是直接以 `tool_call/completed` 且 `result.rejected` 收场。所以 `-p` 只能用于只读或 `--force`，要审批必须走 ACP。这正是契约把 `capabilities` 做成 adapter 运行时自陈、而不是按 agent 种类硬编码的原因。

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
```

契约同步靠 `protocol/fixtures/`：同一份 JSON 被两种语言的测试同时消费，任一侧改了线上格式而没同步另一侧，两边都会红。

## 现状

M0 进行中。已完成：统一契约（TS + Swift 双向往返测试）、眼镜端渲染与导航（分页、审批卡、稳定性保证）、客户端会话状态机（含断连补齐与断档检测）。

未完成：bridge 的进程编排与 HTTP/SSE 传输、端到端加密与二维码配对、iOS UI、真机验证。真机验证依赖 Meta Wearables Developer Center 注册、Meta AI app v272+、眼镜固件 V127+。

## 参考

架构上参考了 [Remodex](https://github.com/Emanuele-web04/remodex)（Apache-2.0）的本地优先 bridge 思路。LensCrew 是独立实现，不使用其名称与品牌。
