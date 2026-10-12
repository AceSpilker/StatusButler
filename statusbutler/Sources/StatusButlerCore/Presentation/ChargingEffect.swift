import Foundation

// 充电动画（A2·S1）：相位纯函数 + 门控策略，渲染与调度分离
public enum ChargingEffectPhase {
    /// 呼吸相位 0...1（正弦半周期，period 默认 2s）
    public static func glow(elapsed: Duration, period: Duration = .seconds(2)) -> Double {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let periodSeconds = Double(period.components.seconds) + Double(period.components.attoseconds) / 1e18
        let x = (seconds / max(periodSeconds, 0.001)) * 2 * .pi
        return (1 - cos(x)) / 2
    }
}

/// 门控：任一条件不满足即关（减弱动态/显示器睡眠/未充电/总开关）
public struct ChargingEffectPolicy: Sendable, Equatable {
    public var enabled: Bool
    public var reduceMotion: Bool
    public var displayAsleep: Bool
    public var isCharging: Bool

    public init(enabled: Bool, reduceMotion: Bool, displayAsleep: Bool, isCharging: Bool) {
        self.enabled = enabled
        self.reduceMotion = reduceMotion
        self.displayAsleep = displayAsleep
        self.isCharging = isCharging
    }

    public var isActive: Bool {
        enabled && isCharging && !reduceMotion && !displayAsleep
    }
}
