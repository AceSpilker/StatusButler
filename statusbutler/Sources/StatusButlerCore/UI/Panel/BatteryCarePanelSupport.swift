import Foundation

// T-212 电池养护页（E13）：充电上限/优化充电状态行 + 月度小结（数据来自 E10 库）。
// 充电上限读不到是 macOS 的真实现状（Apple Silicon 充电管理在 SMC 域，红线二禁写
// 亦无公开读键）——状态行如实"系统未提供"并深链系统设置，绝不编数值（诚实降级）。
// 月度小结聚合全部走纯函数（AGENTS：映射层保持纯函数），测试喂假序列钉死。

// MARK: - 读协议（月度小结要全量，不复用 HistoryReading）

/// 养护页每日点：比面板历史页的 DailyMetricPoint 多一列循环数——月度小结的
/// "循环增量"必须有它，而历史页曲线只要容量，两页口径各自独立
public struct CareDailyPoint: Equatable, Sendable {
    /// yyyy-MM-dd（字典序 == 时间序，与库内排序一致；入参须按日期升序传入）
    public let date: String
    public let batteryCapacityPercent: Int
    public let cycleCount: Int

    public init(date: String, batteryCapacityPercent: Int, cycleCount: Int) {
        self.date = date
        self.batteryCapacityPercent = batteryCapacityPercent
        self.cycleCount = cycleCount
    }
}

/// 月度小结行（一个月一行的聚合值）
public struct CareMonthlySummary: Equatable, Sendable, Identifiable {
    /// yyyy-MM（字典序 == 时间序）
    public let monthKey: String
    /// 当月落库天数（漏记的日期不虚构）
    public let recordedDays: Int
    public let averageCapacityPercent: Int?
    /// 月末-月初容量%（负 = 恶化；单点月为 nil——一个点算不出"变化"）
    public let capacityDelta: Int?
    /// 月末-月初循环数（正 = 累积消耗）
    public let cycleDelta: Int?
    /// 当月"开始充电"事件次数（充电习惯强度）
    public let chargeStartCount: Int

    public var id: String { monthKey }

    public init(
        monthKey: String,
        recordedDays: Int,
        averageCapacityPercent: Int?,
        capacityDelta: Int?,
        cycleDelta: Int?,
        chargeStartCount: Int
    ) {
        self.monthKey = monthKey
        self.recordedDays = recordedDays
        self.averageCapacityPercent = averageCapacityPercent
        self.capacityDelta = capacityDelta
        self.cycleDelta = cycleDelta
        self.chargeStartCount = chargeStartCount
    }
}

/// 养护页读协议（注入；真实实现是同模块 retroactive 适配 HistoryDatabase）。
/// 独立于 HistoryReading：那边的 recentEvents(limit:) 是历史页 UI 的"最近 N 条"
/// 上限口径，月度小结要全量事件计数，被截断的账不是账
public protocol BatteryCareReading: Sendable {
    func careDailySeries() -> [CareDailyPoint]
    func allEvents() -> [EventRow]
}

extension HistoryDatabase: BatteryCareReading {
    public func careDailySeries() -> [CareDailyPoint] {
        ((try? listMetricDaily()) ?? []).map {
            CareDailyPoint(
                date: $0.date,
                batteryCapacityPercent: $0.batteryCapacityPercent,
                cycleCount: $0.cycleCount
            )
        }
    }

    public func allEvents() -> [EventRow] {
        ((try? listEvents()) ?? []).map {
            EventRow(id: $0.id, at: $0.at, kind: $0.kind, detail: $0.detail)
        }
    }
}

// MARK: - 映射（纯函数）

public enum BatteryCareMapping {
    /// 月度聚合：daily 按 yyyy-MM 分桶（容量/循环两组序列），
    /// 事件按 at 前缀(7) 归月、只数 chargeStart。输入空 → 空表（页面走空态引导）
    public static func monthlySummaries(daily: [CareDailyPoint], events: [EventRow]) -> [CareMonthlySummary] {
        var capacitiesByMonth: [String: [Int]] = [:]
        var cyclesByMonth: [String: [Int]] = [:]
        for point in daily {
            let month = String(point.date.prefix(7))
            capacitiesByMonth[month, default: []].append(point.batteryCapacityPercent)
            cyclesByMonth[month, default: []].append(point.cycleCount)
        }
        var chargeStartsByMonth: [String: Int] = [:]
        for event in events where event.kind == HistoryEventKind.chargeStart {
            chargeStartsByMonth[String(event.at.prefix(7)), default: 0] += 1
        }

        let months = Set(capacitiesByMonth.keys).union(chargeStartsByMonth.keys).sorted()
        return months.map { month in
            let capacities = capacitiesByMonth[month] ?? []
            let cycles = cyclesByMonth[month] ?? []
            return CareMonthlySummary(
                monthKey: month,
                recordedDays: capacities.count,
                averageCapacityPercent: capacities.isEmpty
                    ? nil
                    : Int((Double(capacities.reduce(0, +)) / Double(capacities.count)).rounded()),
                capacityDelta: capacities.count >= 2 ? capacities.last! - capacities.first! : nil,
                cycleDelta: cycles.count >= 2 ? cycles.last! - cycles.first! : nil,
                chargeStartCount: chargeStartsByMonth[month] ?? 0
            )
        }
    }

    // MARK: 养护总览行（充电域只读）

    /// 充电上限行主值：macOS 无公开读取键（SMC 域），如实缺测——
    /// "—" 而不是猜一个 80%。文案解释 + 深链出口在视图层
    public static let chargeLimitMissingText = "—"
    /// 充电上限行副文案（解释为什么是"—"）
    public static let chargeLimitExplanation = "macOS 未提供充电上限读取键；调节入口在系统设置 → 电池"
    /// 充电状态行主值：外接/电池 + 是否充电中（IORegistry 既有字段，不虚构）
    public static func chargingStateText(externalConnected: Bool, isCharging: Bool) -> String {
        if isCharging { return "充电中" }
        return externalConnected ? "外接电源（未充电）" : "使用电池"
    }

    /// 养护页曲线点位适配：CareDailyPoint → 历史页折线的输入类型
    /// （复用 T-207 的 BatteryHealthChartView 及其 80% 参考线口径，两页同一张图）
    public static func chartPoints(from daily: [CareDailyPoint]) -> [DailyMetricPoint] {
        daily.map { DailyMetricPoint(date: $0.date, batteryCapacityPercent: $0.batteryCapacityPercent) }
    }
}
