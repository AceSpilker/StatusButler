import Foundation
import Sparkle

// T-055（A2·S11·OG-FR-200）：Sparkle 2 参考式封装。设置页只认 UpdaterController，不直连 Sparkle——
// 换更新引擎/裁剪依赖只动本文件。feed 地址与 EdDSA 公钥以主 bundle Info.plist 为单一事实源
// （SUFeedURL/SUPublicEDKey），代码里不出现真 URL/公钥：上线只改 plist，不动二进制。

/// 更新配置的读取结果。纯函数层（可单测：注入假 dictionary，不碰真 Bundle/Sparkle 运行时）——
/// UpdaterController 只做"读取结果 → Sparkle 行为"的接线
public struct UpdaterFeedInfo: Equatable, Sendable {
    /// 上线占位域（RFC 2606 保留域）：feed 未定稿时的 SUFeedURL 值，绝不当"已配置"参与放行
    public static let placeholderHost = "statusbutler.invalid"

    public let feedURL: URL?
    public let edPublicKey: String?

    /// 真配置 = feed 与非空公钥齐备，且 feed 不是占位域。占位阶段（.invalid/空公钥）一切自动检查
    /// 与手动检查都拦下——宁可用户看不见更新入口，也不向占位域发请求
    public var isConfigured: Bool {
        guard let feedURL, let edPublicKey, !edPublicKey.isEmpty else { return false }
        return feedURL.host() != Self.placeholderHost
    }

    /// 纯函数入口：测试注入假 dict 钉行为；生产侧传 Bundle.main.infoDictionary
    public static func from(infoDictionary dict: [String: Any]) -> UpdaterFeedInfo {
        let feed = (dict["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (dict["SUPublicEDKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return UpdaterFeedInfo(feedURL: feed, edPublicKey: key)
    }
}

@MainActor
public final class UpdaterController: ObservableObject {
    /// 设置页共享单例：SPUStandardUpdaterController 全 App 只允许一个活跃实例
    /// （重复实例会各起一套更新调度），AboutPane 经 body/.task（主隔离上下文）取用
    public static let shared = UpdaterController()

    /// canCheckForUpdates 绑定点（SwiftUI）：Sparkle 检查弹窗期间为 false，按钮据此禁用防重入
    @Published public private(set) var canCheckForUpdates: Bool

    /// Info.plist 读取快照：UI 据此展示"更新通道未开通"占位文案
    public let feedInfo: UpdaterFeedInfo

    /// Sparkle 标准控制器：startingUpdater 绑定 isConfigured——占位阶段不起更新循环
    /// （SUFeedURL 指 .invalid 时启动只会产出噪声失败），上线换真 plist 后自动全量生效
    private let controller: SPUStandardUpdaterController

    public convenience init() {
        self.init(bundle: .main)
    }

    init(bundle: Bundle) {
        let info = UpdaterFeedInfo.from(infoDictionary: bundle.infoDictionary ?? [:])
        feedInfo = info
        controller = SPUStandardUpdaterController(
            startingUpdater: info.isConfigured, updaterDelegate: nil, userDriverDelegate: nil
        )
        canCheckForUpdates = info.isConfigured && controller.updater.canCheckForUpdates
    }

    /// 设置页"检查更新"入口。占位阶段静默拦下（fail-safe）；接线见 AboutPane
    public func checkNow() {
        guard feedInfo.isConfigured, controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }
}
