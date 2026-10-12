import Foundation

// MARK: - 亮度渐变与昼夜调光（T-050a · A11 E14 DDC-03）
// 本文件只做纯数据 + 纯求值：副作用（DDC 写入、定时器）归 DDCClient 与面板接线层。

/// 渐变计划：from → to 的等差序列 + 每步间隔。直接跳变亮度在暗环境观感刺眼，
/// 滑杆/自动化统一走渐变；步数与间隔由调用方按能效权衡（默认建议 10~16 步）。
public struct BrightnessRamp: Equatable, Sendable {
    public let from: Int
    public let to: Int
    /// 步数 = 序列元素数（含首尾）；<1 视为无效计划（空序列，调用方放弃渐变直写终值）
    public let steps: Int
    public let stepDelayMilliseconds: Int

    public init(from: Int, to: Int, steps: Int, stepDelayMilliseconds: Int) {
        self.from = from
        self.to = to
        self.steps = steps
        self.stepDelayMilliseconds = stepDelayMilliseconds
    }

    /// 生成渐变序列（纯函数）：元素数 = steps，首 = clamp(from)、尾 = clamp(to)，
    /// 中间等差四舍五入，每项过 clampDDCValue 出口——单调（升/降由端点次序决定）。
    /// steps == 1 → [to]（一步到位）；steps <= 0 → []。
    public func sequence() -> [Int] {
        guard steps > 1 else { return steps == 1 ? [clampDDCValue(to)] : [] }
        let start = clampDDCValue(from)
        let end = clampDDCValue(to)
        return (0..<steps).map { step in
            let t = Double(step) / Double(steps - 1)
            return clampDDCValue(Int((Double(start) + t * Double(end - start)).rounded()))
        }
    }
}

/// 随昼夜自动调光规则（DDC-03，联动 E23 昼夜主题）：以日出/日落时刻划分昼夜两档。
/// 时刻为当地小时（0-24 带小数）；日间窗口 [sunrise, sunset)。
/// 极端纬度编码约定：极昼 = sunrise 0 / sunset 24（全天日间）；
/// 极夜 = sunrise == sunset（日间窗口为空，全天夜间）；倒挂输入按极夜处理——
/// 宁可整体偏暗，不做无依据的窗口翻转。
public struct DaylightBrightnessRule: Equatable, Sendable {
    public let dayValue: Int
    public let nightValue: Int
    public let sunriseAt: Double
    public let sunsetAt: Double

    public init(dayValue: Int, nightValue: Int, sunriseAt: Double, sunsetAt: Double) {
        self.dayValue = dayValue
        self.nightValue = nightValue
        self.sunriseAt = sunriseAt
        self.sunsetAt = sunsetAt
    }

    /// 纯求值：hour 为当地小时（0-24 带小数，超界输入由区间判断自然兜底）。
    /// 输出经 clampDDCValue 出口——配置脏数据（130/-7）收敛进 0-100，不拒绝整条规则。
    public func value(at hour: Double) -> Int {
        let isDaylight = sunriseAt < sunsetAt && hour >= sunriseAt && hour < sunsetAt
        return clampDDCValue(isDaylight ? dayValue : nightValue)
    }
}
