import Combine
import Foundation

// A14-γ 接线（E10·HS-01/02）：历史落盘调用点——SQLite 三表引擎早已全绿，
// 缺的是"事件检测 + 每日容量 + 启动清账"的订阅者。本文件即该订阅者：
// 订阅 store 快照做翻转检测（翻转才记），Wi-Fi 连断与充电起止落 event_log，
// 每日电池容量落 metric_daily；启动时 applyRetentionPolicy 清过期账。
// 蓝牙等面板旁路域不进本 feed（规格口径：事件日志只收系统级翻转）。

// MARK: - 事件分类（HS-01；字符串钉死落库，改名即破历史数据兼容）

public enum HistoryEventKind {
    public static let wifiConnect = "wifiConnect"
    public static let wifiDisconnect = "wifiDisconnect"
    public static let wiredConnect = "wiredConnect"
    public static let wiredDisconnect = "wiredDisconnect"
    public static let chargeStart = "chargeStart"
    public static let chargeStop = "chargeStop"
}

// MARK: - 每日电池容量读数（metric_daily 数据源抽象）

/// HS-01 每日一行的数据源：真实实现走 IOPowerSources 设计容量口径；
/// 拿不到时集成方可注入"当前电量近似容量"的简版（cycleCount 无来源记 0）。
/// 返回 nil = 本次跳过（明日再记），绝不写占位行污染趋势。
public protocol BatteryCapacityReading: Sendable {
    func read() async -> (capacityPercent: Int, cycleCount: Int)?
}

// MARK: - 历史订阅者

@MainActor
public final class HistoryFeed {
    private let store: SystemStatusStore
    private let details: (any BatteryCapacityReading)?
    /// 库句柄公开只读面（测试与未来体检 UI 查询共用）；nil = 落盘不可用（静默旁路）
    public private(set) var database: HistoryDatabase?
    private var cancellables: Set<AnyCancellable> = []
    /// 翻转检测基线：init 时播种当前快照，之后每帧与之比对
    private var baseline: StatusSnapshot
    /// 当日 metric_daily 是否已记（内存态即可：跨日以 dayKey 变化判定）
    private var lastMetricDay: String?

    /// 线上默认库位：~/Library/Application Support/StatusButler/history.sqlite
    /// （HistoryDatabase 只开库不建目录，目录创建收敛在此）
    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "StatusButler/history.sqlite")
    }

    /// databaseURL 传 nil = 不落库（纯内存旁路，测试用）；开库失败同样静默降级为不落库
    public init(
        store: SystemStatusStore,
        databaseURL: URL? = HistoryFeed.defaultDatabaseURL(),
        details: (any BatteryCapacityReading)? = nil
    ) {
        self.store = store
        self.baseline = store.snapshot
        self.details = details
        if let databaseURL {
            try? FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            self.database = try? HistoryDatabase(url: databaseURL)
        }
    }

    /// 供测试与特殊装配直接注入库句柄（如内存库）
    public init(
        store: SystemStatusStore,
        database: HistoryDatabase?,
        details: (any BatteryCapacityReading)? = nil
    ) {
        self.store = store
        self.baseline = store.snapshot
        self.database = database
        self.details = details
    }

    // MARK: - 生命周期（AppEnvironment 挂接点）

    public func start() {
        // HS-02 启动清账：30/365/90 天保留策略。失败静默（清不成只是多占盘，不挡启动）
        _ = try? database?.applyRetentionPolicy()
        guard cancellables.isEmpty else { return }
        store.$snapshot
            .removeDuplicates()
            .dropFirst()  // 订阅即回放当前值——baseline 已在 init 播种，回放帧不重记
            .sink { [weak self] snapshot in
                self?.process(snapshot)
            }
            .store(in: &cancellables)
    }

    public func stop() { cancellables.removeAll() }

    public var isRunning: Bool { !cancellables.isEmpty }

    // MARK: - 事件检测与落盘

    /// 单帧处理（sink 本体，也是测试的确定性入口）
    public func process(_ snapshot: StatusSnapshot, now: Date = Date()) {
        for event in Self.transitionEvents(from: baseline, to: snapshot) {
            try? database?.recordEvent(at: now, kind: event.kind, detail: event.detail)
        }
        baseline = snapshot
        recordDailyMetricIfNeeded(now: now)
    }

    /// 翻转检测（纯函数，矩阵钉死测试；nonisolated——无隔离状态可跨上下文调用）：
    /// - Wi-Fi：跨"已连接边界"才记——接入/断开各一条；同在线换网（漫游/切网）记一次接入；
    /// - 有线：插拔各一条（与 Wi-Fi 事件可并存，如 Wi-Fi→有线 = 断 Wi-Fi + 接有线）；
    /// - 充电：charging 布尔翻转才记起/止——电量波动、unavailable↔可用一概不记。
    public nonisolated static func transitionEvents(
        from old: StatusSnapshot,
        to new: StatusSnapshot
    ) -> [(kind: String, detail: String?)] {
        var events: [(kind: String, detail: String?)] = []

        // Wi-Fi 断开：old 在线 Wi-Fi 且 new 不是 Wi-Fi
        if case .wifi(let oldSSID, _) = old.link, !isWifi(new.link) {
            events.append((HistoryEventKind.wifiDisconnect, oldSSID))
        }
        // Wi-Fi 接入：new 是 Wi-Fi 且（old 不是 Wi-Fi 或换了网）
        if case .wifi(let newSSID, _) = new.link {
            let roaming: Bool
            if case .wifi(let oldSSID, _) = old.link {
                roaming = oldSSID != newSSID
            } else {
                roaming = true
            }
            if roaming {
                events.append((HistoryEventKind.wifiConnect, newSSID))
            }
        }
        // 有线插拔
        if !isWired(old.link), isWired(new.link) {
            events.append((HistoryEventKind.wiredConnect, nil))
        }
        if isWired(old.link), !isWired(new.link) {
            events.append((HistoryEventKind.wiredDisconnect, nil))
        }
        // 充电起止：两侧都是可用电池态且 charging 翻转
        if case .battery(_, let wasCharging) = old.battery,
           case .battery(_, let isCharging) = new.battery,
           wasCharging != isCharging {
            events.append((isCharging ? HistoryEventKind.chargeStart : HistoryEventKind.chargeStop, nil))
        }
        return events
    }

    private nonisolated static func isWifi(_ link: NetworkLink) -> Bool {
        if case .wifi = link { return true }
        return false
    }

    private nonisolated static func isWired(_ link: NetworkLink) -> Bool {
        if case .wired = link { return true }
        return false
    }

    // MARK: - 每日电池容量（HS-01 metric_daily）

    /// 换日首帧记一行（REPLACE 语义同日覆盖）；无读数源/读数失败 → 跳过。
    /// lastMetricDay 先占位再异步读：读失败不回滚，避免坏读数触发当日重试风暴
    private func recordDailyMetricIfNeeded(now: Date) {
        let day = HistoryDatabase.dayKey(now)
        guard day != lastMetricDay else { return }
        lastMetricDay = day
        guard let details, let database else { return }
        Task {
            guard let reading = await details.read() else { return }
            try? database.recordMetricDaily(
                date: day,
                batteryCapacityPercent: reading.capacityPercent,
                cycleCount: reading.cycleCount
            )
        }
    }
}
