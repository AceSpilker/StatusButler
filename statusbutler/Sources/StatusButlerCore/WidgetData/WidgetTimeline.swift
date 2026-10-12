import Foundation

// T-054a 时间线半场（A6·4）：把单帧快照外推成"当前 + 未来条目"序列。
// 刷新预算耗尽时组件显示的仍是合理估计而非冻结旧值（A6·6 风险应对三件套之二）。
// 全部纯函数——扩展侧 TimelineProvider 消费，主 App 侧单测钉行为，不依赖任何运行时状态。

/// 时间线条目：date 为系统渲染该条目的时刻；isStale 供视图降透明度并显示"管家休息中 · HH:MM 数据"（A6·4）
public struct TimelineEntry: Equatable, Sendable {
    public var date: Date
    public var snapshot: WidgetSnapshot
    public var isStale: Bool

    public init(date: Date, snapshot: WidgetSnapshot, isStale: Bool) {
        self.date = date
        self.snapshot = snapshot
        self.isStale = isStale
    }
}

public enum WidgetTimeline {
    /// 陈旧阈值默认 2 分钟（A6·4）：主 App 退出/睡眠后快照不再更新，组件必须自我标注而非冒充实时
    public static let defaultStaleThreshold: TimeInterval = 120

    /// 陈旧判定：快照生成时间距今**超过** threshold 即陈旧（"超过"取严格大于，恰好等于仍算新鲜）
    public static func staleness(
        generatedAt: Date,
        now: Date,
        threshold: TimeInterval = WidgetTimeline.defaultStaleThreshold
    ) -> Bool {
        now.timeIntervalSince(generatedAt) > threshold
    }

    /// 斜率外推（A6·4）：recentTemps 视为**等间隔**的最高温历史序列（旧→新，末位≈当前），
    /// 约定相邻样本间隔 = stepSeconds（调用方负责按自身采样率先重采样到步进口径，A6·4 的"最近 10 分钟斜率"即此用法）。
    /// 最小二乘求斜率后，从 from 起 stepSeconds 一格、共 count 个条目（首条=当前值，其后逐格外推）；
    /// 其余字段原样沿用，只动 maxCelsius。每条按自身渲染时刻对 generatedAt 做陈旧判定——越外推数据越旧，isStale 逐格点亮。
    public static func extrapolate(
        last: WidgetSnapshot,
        recentTemps: [Double],
        from: Date,
        stepSeconds: Int = 300,
        count: Int = 5
    ) -> [TimelineEntry] {
        guard count > 0 else { return [] }
        let slopePerStep = slope(temps: recentTemps)

        var entries: [TimelineEntry] = []
        entries.reserveCapacity(count)
        for step in 0..<count {
            let date = from.addingTimeInterval(TimeInterval(step * stepSeconds))
            var snapshot = last
            if let current = last.maxCelsius {
                // 物理窗口钳制（A5·TF-01 同窗口）：异常斜率×长步进的外推失控时宁可平坦，绝不显示 500° 假数据
                snapshot.maxCelsius = min(max(current + slopePerStep * Double(step), -40), 150)
            }
            entries.append(
                TimelineEntry(
                    date: date,
                    snapshot: snapshot,
                    isStale: staleness(generatedAt: last.generatedAt, now: date)
                )
            )
        }
        return entries
    }

    /// 最小二乘斜率（x=样本序号，y=温度）。样本不足 2 个时斜率取 0——外推退化为平铺当前值，不猜方向。
    static func slope(temps: [Double]) -> Double {
        let n = temps.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2
        let meanY = temps.reduce(0, +) / Double(n)
        var numerator = 0.0
        var denominator = 0.0
        for (index, value) in temps.enumerated() {
            let dx = Double(index) - meanX
            numerator += dx * (value - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }
}
