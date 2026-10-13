import Foundation

// MARK: - 外接屏亮度面板支持（T-214c · A11 E14 DDC-03 联动 E23）
// 纯映射 + 可注入写管道控制器：DDC 读写副作用只在注入闭包里发生，UI 与测试都不碰真 I2C。

/// 滑杆值 ↔ DDC 值映射（纯函数）：滑杆连续 0-100，DDC 域离散 0-100，
/// 出口统一过 clampDDCValue（不同显示器 MCCS 满量程不一，产品域收 0-100）
public enum DDCBrightnessMapping {
    /// 滑杆 Double → DDC Int：就近取整 + 钳制
    public static func ddcValue(fromSlider raw: Double) -> Int {
        clampDDCValue(Int(raw.rounded()))
    }

    /// DDC Int → 滑杆 Double：读不到（nil，显示器不支持 DDC/CI 读）回落 50——
    /// 滑杆要有起点但绝不能显示 0 吓到用户（0 是"黑屏"的暗示）
    public static func sliderValue(fromDDC value: Int?) -> Double {
        Double(clampDDCValue(value ?? 50))
    }
}

/// 昼夜自动调光控制器：开关开启时（触发源=系统明暗外观变化，见面板接线）按
/// DaylightBrightnessRule 在当前小时的求值目标做渐变写入。
/// 简化口径与 DaylightSwitcher 一致：跟随时机=外观变化，取值=规则按当地小时求值——
/// 触发与取值两口径的偏差（如用户手调系统外观）以规则值为准，外观只当"到点提醒"。
@MainActor
public final class DaylightBrightnessController {
    /// 全注入写面：displays/read/write 闭包 @Sendable（IO 侧可离主线程跑），hour 主隔离读时钟
    public struct Wiring: Sendable {
        public let displays: @Sendable () -> [DDCDisplay]
        public let readBrightness: @Sendable (DDCDisplay) -> Int?
        public let writeBrightness: @Sendable (Int, DDCDisplay) -> Bool
        /// 渐变步间隔（毫秒）：注入 0 即测试免等待
        public let stepDelayMilliseconds: Int

        public init(
            displays: @escaping @Sendable () -> [DDCDisplay],
            readBrightness: @escaping @Sendable (DDCDisplay) -> Int? = { _ in nil },
            writeBrightness: @escaping @Sendable (Int, DDCDisplay) -> Bool = { _, _ in false },
            stepDelayMilliseconds: Int = 30
        ) {
            self.displays = displays
            self.readBrightness = readBrightness
            self.writeBrightness = writeBrightness
            self.stepDelayMilliseconds = stepDelayMilliseconds
        }

        /// live 默认装配：真 DDCClient（符号缺失环境 isAvailable=false → 空屏表自然静默）
        public static func live(ddc: DDCClient = DDCClient()) -> Wiring {
            Wiring(
                displays: { ddc.discoverDisplays() },
                readBrightness: { ddc.readBrightness(of: $0) },
                writeBrightness: { ddc.writeBrightness($0, to: $1) },
                stepDelayMilliseconds: 30
            )
        }
    }

    private let wiring: Wiring
    private let hour: () -> Double
    /// 渐变步数固定档：0→100 全程约 0.4s（12 步 × 30ms），快过 OSD 观感又慢于硬跳
    public static let rampSteps = 12

    public init(wiring: Wiring, hour: @escaping () -> Double = {
        Double(Calendar.current.component(.hour, from: Date()))
            + Double(Calendar.current.component(.minute, from: Date())) / 60
    }) {
        self.wiring = wiring
        self.hour = hour
    }

    /// 渐变计划（纯函数）：读不到当前值（nil）放弃渐变直写终值——
    /// 无起点时造等差序列的第一步就可能大幅跳变，与"防刺眼"初衷相反
    public static func plan(current: Int?, target: Int, steps: Int = rampSteps) -> [Int] {
        guard let current else { return [clampDDCValue(target)] }
        return BrightnessRamp(
            from: current, to: target, steps: steps, stepDelayMilliseconds: 30
        ).sequence()
    }

    /// 求值并写入全部外接屏：rule 按当前小时出目标 → 每屏按起点渐变。
    /// 写失败不重试不中断（DDC-04 静默降级口径），失败一步跳过继续走完序列
    public func reevaluate(rule: DaylightBrightnessRule) async {
        let target = rule.value(at: hour())
        let displays = wiring.displays()
        guard !displays.isEmpty else { return }
        let delayMs = wiring.stepDelayMilliseconds
        for display in displays {
            let steps = Self.plan(current: wiring.readBrightness(display), target: target)
            for (index, value) in steps.enumerated() {
                _ = wiring.writeBrightness(value, display)
                if index < steps.count - 1, delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
        }
    }
}
