import Foundation

// E1 信号槽 v1（A8·SL）：槽位源协议 + 注册表 + 组合器。
// A14-γ 接线：netSpeed/cpuUsage/memoryPressure 从 PerfBus 缓存读（PerfEngine 驱动）、
// temperature=ThermalSlot（60s 缓存兜底）、weather=WeatherSlot（读共享缓存）、
// 脚本插件槽启动扫一次并入；音量/时钟/电池%/磁盘/日历倒数保持原实现。
public struct SlotScene: Equatable, Sendable {
    public var symbol: String?
    public var valueText: String?
    public var level: Int?        // 0...4 分级点
    public var isWarning: Bool    // true = 红色警示

    public init(symbol: String? = nil, valueText: String? = nil, level: Int? = nil, isWarning: Bool = false) {
        self.symbol = symbol
        self.valueText = valueText
        self.level = level
        self.isWarning = isWarning
    }
}

public protocol SlotSource: Sendable {
    var id: String { get }
    /// 返回 nil = 该源当前无数据（注册表中保留占位）
    func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene?
}

// MARK: - 内置源（快照/时钟即时推导）

public struct VolumeSlot: SlotSource {
    public let id = "volume"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        let dots = snapshot.volume.isMuted
            ? 0
            : Int((Double(snapshot.volume.level) / 100 * 4).rounded())
        return SlotScene(
            symbol: snapshot.volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            valueText: nil,
            level: dots,
            isWarning: snapshot.volume.isMuted
        )
    }
}

public struct ClockSlot: SlotSource {
    public let id = "clock"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return SlotScene(symbol: nil, valueText: formatter.string(from: now), level: nil)
    }
}

public struct BatteryPercentSlot: SlotSource {
    public let id = "batteryPercent"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard case .battery(let level, _) = snapshot.battery else { return nil }
        return SlotScene(
            symbol: "battery.100",
            valueText: "\(level)%",
            level: Int((Double(level) / 100 * 4).rounded()),
            isWarning: level <= 20
        )
    }
}

public struct DiskFreeSlot: SlotSource {
    public let id = "diskFree"
    private let available: @Sendable () -> Int64?
    public init(available: @escaping @Sendable () -> Int64? = { nil }) {
        self.available = available
    }
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard let bytes = available() else { return nil }
        let gb = Double(bytes) / 1e9
        return SlotScene(symbol: "internaldrive", valueText: String(format: "%.0fG", gb), level: nil)
    }
}

// MARK: - 性能三源（A7·PF：从 PerfBus 缓存同步读，采样由 PerfEngine 引用计数驱动）

/// 网速槽位：显示下行速率（菜单栏空间有限，"网速"的主观口径是下载；
/// 上行进弹层性能分区）。引擎未启动/首帧未到 → nil（注册表保留占位）。
public struct NetSpeedSlot: SlotSource {
    public static let slotID = "netSpeed"
    public let id = NetSpeedSlot.slotID

    private let bus: PerfBus

    public init(bus: PerfBus = PerfEngine.shared.bus) {
        self.bus = bus
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard let rates = bus.sample?.net else { return nil }
        return Self.scene(forBytesPerSec: rates.bytesInPerSec)
    }

    /// 人类可读速率（纯函数，钉死测试）：B/s → KB/s → MB/s 三档，
    /// 档内一位小数到 10 为界（10 以上小数无信息量还占宽度）
    public static func speedText(bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 KB/s" }
        if bytesPerSec < 1024 { return "\(Int(bytesPerSec)) B/s" }
        if bytesPerSec < 1024 * 1024 {
            let kb = bytesPerSec / 1024
            return kb < 10 ? String(format: "%.1f KB/s", kb) : String(format: "%.0f KB/s", kb)
        }
        let mb = bytesPerSec / (1024 * 1024)
        return mb < 100 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f MB/s", mb)
    }

    /// 量级分点（纯函数）：<1KB 0 点（静默）、<100KB 1、<1MB 2、<10MB 3、≥10MB 4
    public static func level(forBytesPerSec bytesPerSec: Double) -> Int? {
        switch bytesPerSec {
        case ..<1024: return 0
        case ..<(100 * 1024): return 1
        case ..<(1024 * 1024): return 2
        case ..<(10 * 1024 * 1024): return 3
        default: return 4
        }
    }

    public static func scene(forBytesPerSec bytesPerSec: Double) -> SlotScene {
        SlotScene(
            symbol: "network",
            valueText: speedText(bytesPerSec: bytesPerSec),
            level: level(forBytesPerSec: bytesPerSec),
            isWarning: false  // 网速无"危险"语义，警示位留给温度/CPU 等有物理边界的域
        )
    }
}

/// CPU 占用槽位：总占用%（perCore 属弹层性能分区，不进菜单栏）。
public struct CpuUsageSlot: SlotSource {
    public static let slotID = "cpuUsage"
    public let id = CpuUsageSlot.slotID

    private let bus: PerfBus

    public init(bus: PerfBus = PerfEngine.shared.bus) {
        self.bus = bus
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard let cpu = bus.sample?.cpu else { return nil }
        return Self.scene(forTotalPercent: cpu.totalPercent)
    }

    public static func scene(forTotalPercent percent: Double) -> SlotScene {
        SlotScene(
            symbol: "cpu",
            valueText: "\(Int(percent.rounded()))%",
            level: min(4, Int(percent / 25)),
            isWarning: percent >= 90
        )
    }
}

/// 内存压力槽位：已用口径 = active+wired+compressed（MemoryMonitor 的 used 口径），
/// 占总量比例分档展示。
public struct MemoryPressureSlot: SlotSource {
    public static let slotID = "memoryPressure"
    public let id = MemoryPressureSlot.slotID

    private let bus: PerfBus

    public init(bus: PerfBus = PerfEngine.shared.bus) {
        self.bus = bus
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard let memory = bus.sample?.memory, memory.totalBytes > 0 else { return nil }
        return Self.scene(forUsedRatio: Double(memory.usedBytes) / Double(memory.totalBytes))
    }

    public static func scene(forUsedRatio ratio: Double) -> SlotScene {
        SlotScene(
            symbol: "memorychip",
            valueText: "\(Int((ratio * 100).rounded()))%",
            level: level(forUsedRatio: ratio),
            isWarning: ratio >= 0.9
        )
    }

    /// 压力分档（纯函数）：<50% 宽裕 1 点、<70% 正常 2、<85% 吃紧 3、≥85% 4（≥90% 另亮警示）
    public static func level(forUsedRatio ratio: Double) -> Int? {
        switch ratio {
        case ..<0.5: return 1
        case ..<0.7: return 2
        case ..<0.85: return 3
        default: return 4
        }
    }
}

// MARK: - 温度槽位（A5·TF：ThermalMonitoring 注入读 maxCelsius，60s 缓存兜底）

/// 温度槽位。SlotSource.scene() 是同步协议而 SMC 读取是异步阻塞——沿用
/// PluginSlot/CalendarSlot 的"到期判定 + 后台触发 + 立即返回缓存"形态：
/// 渲染线程零 IO；60 秒内重复拉取只吃缓存（缓存兜底），读取失败保留上次值。
public struct ThermalSlot: SlotSource {
    public static let slotID = "temperature"
    public let id = ThermalSlot.slotID

    /// 缓存有效期：菜单栏温度观感 60s 足够，SMC 读取也非零成本（A5 能效）
    public static let refreshInterval: TimeInterval = 60

    private let thermal: any ThermalMonitoring
    private let cache: ThermalValueCache

    public init(thermal: any ThermalMonitoring = ThermalMonitor()) {
        self.thermal = thermal
        self.cache = ThermalValueCache()
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        // 有人看才运行：渲染拉取触发后台读；新鲜期内直接吃缓存
        if cache.shouldRefresh(interval: Self.refreshInterval, now: now),
           cache.markRefreshStarted(now: now) {
            let thermal = self.thermal
            let cache = self.cache
            Task.detached(priority: .utility) {
                let reading = await thermal.read()
                cache.apply(reading?.maxCelsius, now: Date())
            }
        }
        return cache.value.flatMap(Self.scene(forCelsius:))
    }

    /// 场景映射（纯函数，钉死测试）
    public static func scene(forCelsius celsius: Double) -> SlotScene {
        SlotScene(
            symbol: "thermometer.medium",
            valueText: String(format: "%.0f°", celsius),
            level: level(forCelsius: celsius),
            isWarning: celsius >= 90
        )
    }

    /// 分档：<40° 轻载 1、<60° 正常 2、<80° 偏高 3、≥80° 满载 4（≥90° 另亮警示）
    public static func level(forCelsius celsius: Double) -> Int? {
        switch celsius {
        case ..<40: return 1
        case ..<60: return 2
        case ..<80: return 3
        default: return 4
        }
    }
}

/// 温度值缓存：最近一次成功读数 + 刷新调度状态。
/// 锁纪律同 PluginSlot.SceneCache：可变态全在锁内，锁内无回调无 IO。
final class ThermalValueCache: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue: Double?
    private var lastRead: Date?
    private var inFlight = false

    var value: Double? { lock.withLock { currentValue } }

    /// 到期判定：无在途读取、距上次发起 ≥ 80% 缓存期（间隔/5 宽忍，防到期空档闪烁）
    func shouldRefresh(interval: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            if inFlight { return false }
            guard let last = lastRead else { return true }
            return now.timeIntervalSince(last) >= interval * 0.8
        }
    }

    /// 占位发起：锁内双检 inFlight，并发拉取只放行第一个
    func markRefreshStarted(now: Date) -> Bool {
        lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            lastRead = now
            return true
        }
    }

    /// 读数回写：nil（SMC 不可用）不清旧值——迟到的温度好过闪烁消失；
    /// 全 nil 场景（虚拟机）value 恒 nil，槽位按协议返回 nil 降级
    func apply(_ reading: Double?, now: Date) {
        lock.withLock {
            inFlight = false
            if let reading { currentValue = reading }
        }
    }
}

// MARK: - 天气槽位（A8·WX：读共享缓存，调度由 WeatherFeed 驱动）

public struct WeatherSlot: SlotSource {
    public static let slotID = "weather"
    public let id = WeatherSlot.slotID

    private let cache: WeatherCache

    public init(cache: WeatherCache = WeatherBus.cache) {
        self.cache = cache
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        // lastKnown 而非 fresh：过期值也是"上次成功"的合法展示（WX-03-3 失败静默口径）
        guard let weather = cache.lastKnown() else { return nil }
        return Self.scene(for: weather)
    }

    public static func scene(for weather: WeatherNow) -> SlotScene {
        let symbolism = WeatherNow.symbolism(code: weather.weatherCode)
        return SlotScene(
            symbol: symbolism.symbol,
            valueText: String(format: "%.0f°", weather.temperatureC),
            level: nil,
            isWarning: false  // 天气无警示语义
        )
    }
}

// MARK: - 注册表与组合器

/// 保留占位类型：SettingsChrome 以 `is PendingSlot` 判定"待数据源"灰显。
/// A14-γ 后内置五占位已全部换真源，注册表暂无实例；类型保留给未来数据源占位用。
struct PendingSlot: SlotSource {
    let id: String
    func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? { nil }
}

public enum SlotRegistry {
    /// 插件执行器（跨插件共享失败计数，SP-02）
    static let pluginRunner = PluginRunner()

    /// 完整注册表：内置真源 + 脚本插件槽。
    /// pluginRoot 是扫描注入点（测试钉"扫描→注册"链路）；nil = 线上默认目录。
    public static func slots(pluginRoot: URL?) -> [String: any SlotSource] {
        var map: [String: any SlotSource] = [
            VolumeSlot().id: VolumeSlot(),
            ClockSlot().id: ClockSlot(),
            BatteryPercentSlot().id: BatteryPercentSlot(),
            DiskFreeSlot().id: DiskFreeSlot(),
        ]
        // 性能三源绑共享引擎的总线：引擎 start 后首帧到达前 scene() 返回 nil（占位语义）
        let bus = PerfEngine.shared.bus
        map[NetSpeedSlot.slotID] = NetSpeedSlot(bus: bus)
        map[CpuUsageSlot.slotID] = CpuUsageSlot(bus: bus)
        map[MemoryPressureSlot.slotID] = MemoryPressureSlot(bus: bus)
        map[ThermalSlot.slotID] = ThermalSlot()
        map[WeatherSlot.slotID] = WeatherSlot(cache: WeatherBus.cache)
        map["calendarCountdown"] = CalendarSlot(provider: LiveEventStore())
        // 脚本插件（SP-01/SP-03）：启动扫一次；目录不存在/条目损坏/扫描异常 → 空表，
        // 绝不影响内置源。重复 id（含与内置撞名）后者覆盖，扫描侧已按 manifest 去重
        let root = pluginRoot ?? PluginDirectory.defaultRoot()
        for (manifest, scriptURL) in PluginDirectory.scan(root: root) {
            let slot = PluginSlot(manifest: manifest, scriptPath: scriptURL.path, runner: pluginRunner)
            map[slot.id] = slot
        }
        return map
    }

    /// 首批可用源的惰性单例（A8·SL-02 全表；首次访问即完成一次插件扫描）
    public static let builtin: [String: any SlotSource] = slots(pluginRoot: nil)

    public static func source(id: String) -> (any SlotSource)? {
        builtin[id]
    }
}

/// 底部槽位组合器：按设置取活动源，产出场景
public struct SlotComposer: Sendable {
    public let selectedID: String
    public init(selectedID: String) { self.selectedID = selectedID }

    public func footer(snapshot: StatusSnapshot, now: Date = Date()) -> SlotScene? {
        SlotRegistry.source(id: selectedID)?.scene(snapshot: snapshot, now: now)
    }
}
