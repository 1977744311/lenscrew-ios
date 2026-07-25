// swift-tools-version: 6.0
// LensCrewKit —— 纯逻辑层零第三方依赖，swift test 可在 macOS 直接跑，不需要眼镜也不需要 SDK。
// 真实 Meta Wearables DAT 绑定收敛在 App 工程（见 project.yml），
// 适配器源文件位于 App/Adapters/ 并以 canImport 守护。
import PackageDescription

let package = Package(
    name: "LensCrewKit",
    // watchOS 只消费 AgentProtocol（Foundation-only）；手表 target 不引 BridgeLink 等网络/SDK 层
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "BridgeLink", targets: ["BridgeLink"]),
        .library(name: "GlassesKit", targets: ["GlassesKit"]),
        .library(name: "GlassRenderer", targets: ["GlassRenderer"]),
        .library(name: "LensCrewCore", targets: ["LensCrewCore"]),
    ],
    targets: [
        .target(name: "AgentProtocol"),
        .target(name: "GlassesKit"),
        .target(name: "BridgeLink", dependencies: ["AgentProtocol"]),
        .target(name: "GlassRenderer", dependencies: ["AgentProtocol", "GlassesKit"]),
        .target(name: "LensCrewCore", dependencies: [
            "AgentProtocol", "BridgeLink", "GlassesKit", "GlassRenderer",
        ]),
        // 契约 fixture 与 bridge 侧共用 protocol/fixtures/，用 #filePath 定位而不打包进
        // 测试 bundle：同一份文件被两种语言的测试同时消费，任一侧漂移都会红。
        .testTarget(name: "AgentProtocolTests", dependencies: ["AgentProtocol"]),
        .testTarget(name: "BridgeLinkTests", dependencies: ["BridgeLink"]),
        .testTarget(name: "GlassRendererTests", dependencies: ["GlassRenderer"]),
        .testTarget(name: "LensCrewCoreTests", dependencies: ["LensCrewCore"]),
    ]
)
