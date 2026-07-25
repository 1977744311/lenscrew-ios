# 贡献指南

## 开发环境

- **macOS** + **Xcode 16+**（Swift 6 toolchain；库层用 `swift test`，不需要 Xcode 工程也能跑）
- **Node ≥ 22.18**：bridge 直接跑 TS（类型擦除，不做构建产物）。运行 bridge 零依赖；开发需要一次 `cd bridge && npm install` 拿 `typescript`（唯一 devDependency，用于 `tsc --noEmit`）
- **xcodegen**（`brew install xcodegen`）：`LensCrew.xcodeproj` 不入库，由 `project.yml` 生成
- 至少一个 agent CLI（`codex` / `claude` / `cursor-agent`）便于真实联调；单元测试不需要，adapter 测试全部基于实测录制的 fixture

## 测试

改动必须让这三条全绿：

```bash
swift test                                    # 库层（LensCrewKit），无需 SDK、无需眼镜
cd bridge && node --test 'test/**/*.test.ts'  # bridge 单测
cd bridge && npx tsc --noEmit                 # 类型检查
```

端到端链路由 `Tests/LensCrewCoreTests/EndToEndTests.swift` 覆盖：真起 bridge 进程，一路验到眼镜屏上出现审批卡。它包含在 `swift test` 里。

## 双语 fixture 契约

`protocol/fixtures/` 是 TS 与 Swift 的共同事实源：同一份 JSON 被 `bridge/test/` 与 `Tests/` 同时消费。

- **改线上格式（bridge 事件、E2EE 帧、adapter 输出）必须同步两侧**——只改一侧，两边测试同红，这是设计出来的护栏，不要绕过它
- fixture 来自对真实运行时的实测录制，不是手写的理想样本；新增 adapter 行为时先录 fixture 再写代码
- 契约的判定权在 `bridge/src/protocol/`，`Sources/AgentProtocol/` 是它的 Swift 同构镜像

## 铁律

1. **库层零第三方依赖**：`Package.swift`（LensCrewKit）与 bridge 运行时不引入任何第三方包。bridge 只允许 devDependencies（现在只有 `typescript`）；真实 SDK 绑定只允许出现在 App target 的 `App/Adapters/`。新增运行时依赖默认拒绝，除非有无法用标准库完成的强理由
2. **密钥绝不入库**：`Secrets.xcconfig`、`apns.json`、`*.p8`、`*.mobileprovision`、`~/.lenscrew` 状态文件都在 `.gitignore` 里；只提交 `*.example.*` 模板，模板里只用脱敏占位值。提交前自查 diff 里没有真实凭据、生产端点与个人信息
3. **运行时差异只允许存在于 adapter**：三个 agent 的行为差异收敛在 `bridge/src/adapters/`，`GlassesKit` 是 DAT SDK 的唯一抽象边界，不要让差异泄漏到统一契约之外

## 提交规范

- 提交信息用**英文祈使句**，正文说明**为什么**改，而不是复述改了什么
- 小步提交：一个提交解决一件事，测试跟随行为改动
- 不引入阶段标签（M0 / M1 之类）；README 的「能力 / 未补全」清单是唯一的状态口径

## 提 PR 前

1. 三条测试命令全绿
2. 若改了线上格式：`protocol/fixtures/` 与两侧解析代码同步更新
3. 若改了 CLI flag 或配置文件格式：同步 README 与 `docs/` 对应文档
