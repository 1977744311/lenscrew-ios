# 眼镜功能自建指南（Meta Ray-Ban Display）

LensCrew 的眼镜端跑在 Meta Wearables Device Access Toolkit（DAT）上。**本项目不分发 iOS 安装包**，要用眼镜功能，需要你自己注册 Meta 开发者、申请凭据、Xcode 签名自打包。整个流程一次性走完约 30 分钟。

## 为什么不发安装包

- **Apple 侧**：遵守 Apple Developer Program 条款，个人开发者签名的构建不适合对外再分发
- **Meta 侧**：DAT 处于 developer preview，未发布应用只能自建，或走邀请制 release channel

这与 turbometa、remodex 等项目的源码自建分发模式一致：clone 仓库、填自己的凭据、自己签名装机。

**没有眼镜、没有 Meta 凭据也完全可以用 LensCrew**：模拟器自动走 Mock 眼镜，真机上没有凭据时眼镜功能保持休眠，手机端六屏全部可用。DAT SDK 是 `project.yml` 里的公开 SPM 依赖（[facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios)），编译不需要任何私有源。

## 版本依赖

固件与 App 版本要求**随 DAT SDK 版本走**，以 [Meta 官方文档](https://wearables.developer.meta.com/)的版本矩阵为准。本仓库当前锁定：

| DAT SDK（project.yml 锁定） | 眼镜固件 | Meta AI App（iOS） |
|---|---|---|
| 0.8.0 | V127+ | v272+ |

升级 SDK 前先查官方矩阵，眼镜固件在 Meta AI App 里触发更新。

## 五步走

### ① 打开 Meta AI App 开发者模式

手机上的 Meta AI App：**设置 → 应用信息 → 版本号连点 5 次**，出现开发者选项。

### ② 核对版本

按上表确认眼镜固件与 Meta AI App 版本达标（版本号在 Meta AI App 的眼镜设备页可见）。

### ③ 注册 Meta 开发者、拿 iOS 凭据

1. 到 [Meta Wearables Developer Center](https://wearables.developer.meta.com/) 注册开发者账号
2. 新建一个 Project
3. 在项目的 iOS 集成配置里拿到两个值：**MetaAppID** 与 **ClientToken**

### ④ 填进 LensCrew 的 MWDAT 配置

```bash
cp App/Support/Secrets.example.xcconfig App/Support/Secrets.xcconfig
```

编辑 `App/Support/Secrets.xcconfig`，填入上一步的两个值：

```
MWDAT_META_APP_ID = <你的 MetaAppID>
MWDAT_CLIENT_TOKEN = <你的 ClientToken>
```

`Secrets.xcconfig` 已被 `.gitignore` 排除，凭据只留在你本机；构建时它经工程配置注入 App 的 MWDAT 配置。仓库里只有 `Secrets.example.xcconfig` 模板。

### ⑤ Xcode 签名、真机运行

```bash
brew install xcodegen
xcodegen generate
open LensCrew.xcodeproj
```

Xcode 里：

1. Target `LensCrew` → Signing & Capabilities → 选你自己的 Team（个人免费 Team 也行）
2. **改 Bundle ID** 为你独有的（默认 `dev.steven.LensCrew` 属于原作者的前缀）
3. 选中真机运行；首次装机后到 iPhone 的 **设置 → 通用 → VPN 与设备管理** 信任你的开发者证书

免费个人 Team 的两个已知限制：

- 描述文件 7 天过期，到期重新构建安装即可
- 不支持推送能力——若签名报 Push Notifications 相关错误，在 Signing & Capabilities 里移除该 capability（或本地删掉 `App/Support/LensCrew.entitlements` 里的 `aps-environment` 键）再构建；这只影响 APNs 推送（见 [push-apns-setup.md](push-apns-setup.md)），眼镜与其余功能不受影响

## 运行

App 装好后，眼镜经 Meta AI App 与手机配对；LensCrew 的「眼镜」页里能看到连接状态（模拟器上标注 Mock）。眼镜端四屏——会话列表 / 流水 / 块详情 / 审批卡——的交互约束见 README「眼镜端约束」一节。

## 常见问题

- **编译报缺 Secrets.xcconfig？** 不应发生：没有该文件也能编译（眼镜功能休眠）。若遇到请提 issue
- **眼镜连不上？** 依次检查：开发者模式已开、版本达标、MetaAppID / ClientToken 填对、Bundle ID 与 Meta Project 配置一致
- **不想用眼镜，只想要手机指挥台？** 跳过本文全部步骤，直接 `xcodegen generate` 签名装机即可
