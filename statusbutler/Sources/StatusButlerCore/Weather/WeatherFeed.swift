import Foundation

// A14-γ 接线（A8·WX-03-3/WX-06）：天气刷新调度——OpenMeteoProvider 与 WeatherCache
// 引擎侧早已全绿，缺的是"30 分钟节拍 + 可见性闸门"的调用点。本文件即该调用点：
// 可见才取数、缓存新鲜短路、失败静默留旧值（quietFailureText 语义，不重试不报错）。

/// 共享缓存命名空间：槽位注册表（非隔离装配）与调度器必须共用同一份缓存。
/// 用 enum 而非挂在 @MainActor 类上的 static，是避免静态属性的 MainActor 隔离
/// 传染进 SlotRegistry 的非隔离装配路径。
public enum WeatherBus {
    public static let cache = WeatherCache()
}

/// 天气调度器：30 分钟节拍循环 + 注入化闸门。
/// 可见性 provider 是"有人看才取数"的闸门注入点（弹层可见/槽位选中/设置总开关，
/// 集成方决定口径）；默认恒 true = 简单定时器模式（本任务口径）。
@MainActor
public final class WeatherFeed {
    /// WX-03-3：调度周期与缓存 TTL 同为 30 分钟——节拍到点时缓存恰好临界，
    /// 一次取数即续满，周期与 TTL 错开会造成"到点仍新鲜白跑一趟"或"过期无人补"
    public static let refreshInterval: TimeInterval = 30 * 60

    private let provider: any WeatherProviding
    private let cache: WeatherCache
    private let location: @Sendable () -> (latitude: Double, longitude: Double)?
    private let isVisible: @Sendable () -> Bool
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    /// location 默认 nil（A8·WX-01 规格是"默认手动城市"——城市表属设置层后续接入；
    /// 无定位时 tick 短路，缓存为空 → weather 槽位按协议返回 nil 降级）
    public init(
        provider: any WeatherProviding = OpenMeteoProvider(),
        cache: WeatherCache = WeatherBus.cache,
        location: @escaping @Sendable () -> (latitude: Double, longitude: Double)? = { nil },
        isVisible: @escaping @Sendable () -> Bool = { true },
        interval: TimeInterval = WeatherFeed.refreshInterval
    ) {
        self.provider = provider
        self.cache = cache
        self.location = location
        self.isVisible = isVisible
        self.interval = interval
    }

    // MARK: - 生命周期（AppEnvironment 挂接点）

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(
                    for: .seconds(self.interval),
                    tolerance: .seconds(self.interval / 5)
                )
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public var isRunning: Bool { task != nil }

    // MARK: - 节拍决策

    /// 一次节拍（循环本体，也是测试/手动刷新的确定性入口）：
    /// 不可见 / 无定位 / 缓存仍新鲜 → 跳过；取数成功 → store 续期；
    /// 失败 → 什么都不做（旧值原样保留，quietFailureText 语义——重试退避由
    /// 下一节拍天然承担，杜绝重试风暴）。
    public func tick(now: Date = Date()) async {
        guard isVisible(), let coordinate = location() else { return }
        if let last = cache.lastKnown(),
           WeatherCache.isFresh(fetchedAt: last.fetchedAt, now: now, ttl: WeatherCache.ttl) {
            return
        }
        let result = await provider.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if case .success(let weather) = result {
            cache.store(weather)
        }
    }
}
