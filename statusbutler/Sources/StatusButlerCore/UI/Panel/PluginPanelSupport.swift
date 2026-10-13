import Foundation

// T-213 插件管理页（E16·SP-03）：扫描列表（manifest 字段 + 健康状态）+
// 启停/重载 + 三连击复位说明。管理页是面板旁路（只读扫描 + 经闭包下指令），
// 扫描/执行引擎（PluginDirectory / PluginRunner）已有，此处只做展示映射与决策。

// MARK: - 管理页单行

/// 插件管理页单行（manifest 字段 + 连败计数 → 健康状态）
public struct PluginRowState: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let author: String?
    /// 解释器绝对路径（白名单成员；视图取 lastPathComponent 展示）
    public let interpreter: String
    public let refreshHintSeconds: Int
    /// 连续失败/超时计数（PluginRunner.failureCount 透传）
    public let failureCount: Int

    public init(
        id: String,
        name: String,
        author: String?,
        interpreter: String,
        refreshHintSeconds: Int,
        failureCount: Int
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.interpreter = interpreter
        self.refreshHintSeconds = refreshHintSeconds
        self.failureCount = failureCount
    }

    public var health: PluginHealth { PluginPanelMapping.health(failureCount: failureCount) }
}

// MARK: - 健康状态（决策纯函数）

/// 三连击健康分档：0 连败正常；1-2 连败仍在跑但已劣化；满 3 自动停用
public enum PluginHealth: Equatable, Sendable {
    case healthy
    case degraded
    case stopped

    public var displayName: String {
        switch self {
        case .healthy: return "正常"
        case .degraded: return "连败中"
        case .stopped: return "已停用"
        }
    }
}

public enum PluginPanelMapping {
    /// 连败计数 → 健康分档。停用门限复用 PluginRunner.shouldDisable
    /// （三连击规则的唯一事实源，管理页不得另立标准）
    public static func health(failureCount: Int) -> PluginHealth {
        if PluginRunner.shouldDisable(failures: failureCount) { return .stopped }
        return failureCount == 0 ? .healthy : .degraded
    }

    /// 停用插件是否需要复位才能恢复：满 3 连败后 PluginRunner 零成本短路拒跑，
    /// runner.reset（"重载"按钮背后的动作）是唯一恢复通道
    public static func needsReset(_ health: PluginHealth) -> Bool {
        health == .stopped
    }

    /// 扫描结果 + 连败计数 → 管理页行（纯函数；主线接线在闭包里调它）
    public static func rows(
        from scan: [(manifest: PluginManifest, scriptURL: URL)],
        failureCount: (String) -> Int
    ) -> [PluginRowState] {
        scan.map { entry in
            PluginRowState(
                id: entry.manifest.id,
                name: entry.manifest.name,
                author: entry.manifest.author,
                interpreter: entry.manifest.interpreter,
                refreshHintSeconds: entry.manifest.refreshHintSeconds,
                failureCount: failureCount(entry.manifest.id)
            )
        }
    }

    /// 三连击复位说明（页脚常量——规则文案与 PluginRunner.shouldDisable 同源，
    /// 写死"3"是因为门限即产品规则，两处漂移由测试钉死）
    public static let tripleStrikeExplanation =
        "插件连续失败/超时满 3 次会自动停用（零成本短路，不再执行）。「重载」复位连败计数并重新启用——这是停用插件的唯一恢复通道。"
}

// MARK: - 注入类型（主线接线清单见 PanelViewModel.init 各参数注记）

/// 管理页列表 provider：主线在闭包里做 PluginDirectory.scan(defaultRoot()) +
/// PluginRunner.failureCount 求值（文件扫描轻量，进入页面才调用——按需数据，
/// 不轮询；能效铁律"有人看才运行"）
public typealias PluginListProvider = @Sendable () -> [PluginRowState]

/// 重载动作（id → runner.reset(id)）：计数清零即恢复启用，下一轮渲染自然重跑。
/// 不带返回值——结果经 refreshPluginRows() 重扫反映，不伪装即时成功
public typealias PluginReloadAction = @Sendable (String) -> Void
