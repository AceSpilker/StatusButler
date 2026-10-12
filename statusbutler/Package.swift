// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StatusButler",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StatusButler", targets: ["StatusButler"])
    ],
    dependencies: [
        // T-055（A2·S11·OG-FR-200）：Sparkle 2 EdDSA 自动更新。二进制 xcframework 走网络拉取，
        // 本地首包/CI 变慢属正常；产品取完整 Sparkle（含 XPC autoupdate）而非 SparkleCore
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "StatusButlerCore",
            dependencies: [
                // Sparkle 只经由 Core 引入：UpdaterController（App/UpdaterController.swift）与
                // 设置页 AboutPane 同模块，主 App 不直连——换更新引擎只动 Core 一处
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/StatusButlerCore"
        ),
        .executableTarget(
            name: "StatusButler",
            dependencies: ["StatusButlerCore"],
            path: "Sources/StatusButler"
        ),
        .executableTarget(
            name: "butler",
            dependencies: ["StatusButlerCore"],
            path: "Sources/statusbutler-cli"
        ),
        // T-054（A6·2/A6·5）：WidgetKit 扩展。SPM 没有 appex 产品类型——产出普通可执行文件，
        // 由 scripts/assemble-appex.sh 组装成 .app 内 PlugIns/StatusButlerWidgets.appex；
        // 视图/Provider/注册表全部复用 Core 的 WidgetUI/WidgetData（canImport 保护段），
        // 本 target 只有 @main 组装，加族不在此另写一份（防回归：target 名大小写不敏感查重有测试钉死）
        .executableTarget(
            name: "StatusButlerWidgets",
            dependencies: ["StatusButlerCore"],
            path: "Sources/StatusButlerWidgets"
        ),
        .testTarget(
            name: "StatusButlerCoreTests",
            dependencies: ["StatusButlerCore"],
            path: "Tests/StatusButlerCoreTests"
        )
    ]
)
