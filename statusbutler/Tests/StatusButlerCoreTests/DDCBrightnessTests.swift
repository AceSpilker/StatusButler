import Foundation
import IOKit
import Testing

@testable import StatusButlerCore

// T-050a: DDC 值域钳制 / 帧构造 / 渐变序列 / 昼夜规则纯逻辑 + dlsym 降级注入 + live 冒烟
@Suite struct DDCBrightnessTests {

    // MARK: - 值域钳制

    @Test func clampDDCValuePinsToClosedRange() {
        #expect(clampDDCValue(Int(Int16.min)) == 0)
        #expect(clampDDCValue(-1) == 0)
        #expect(clampDDCValue(0) == 0)
        #expect(clampDDCValue(1) == 1)
        #expect(clampDDCValue(50) == 50)
        #expect(clampDDCValue(99) == 99)
        #expect(clampDDCValue(100) == 100)
        #expect(clampDDCValue(101) == 100)
        #expect(clampDDCValue(Int(Int16.max)) == 100)
    }

    // MARK: - DDC/CI 帧（ddcctl 社区口径验算）

    @Test func ddcFramesMatchCommunityChecksumConventions() {
        // 设值：亮度寄存器 0x10 写 100(0x64)——校验和 0x50+0x82+0x03+0x10+0x00+0x64=329→0x49
        #expect(DDCFrame.setValueCommand(register: 0x10, value: 100)
                == [0x51, 0x82, 0x03, 0x10, 0x00, 0x64, 0x49])
        // 设值：对比度寄存器 0x12 写 0——校验和 0x50+0x82+0x03+0x12+0x00+0x00=231=0xE7
        #expect(DDCFrame.setValueCommand(register: 0x12, value: 0)
                == [0x51, 0x82, 0x03, 0x12, 0x00, 0x00, 0xE7])
        // 读值：亮度寄存器请求——校验和 0x50+0x82+0x01+0x10=80+130+1+16=227=0xE3
        #expect(DDCFrame.getValueCommand(register: 0x10)
                == [0x51, 0x82, 0x01, 0x10, 0xE3])
        // 读值：对比度寄存器请求——229=0xE5
        #expect(DDCFrame.getValueCommand(register: 0x12)
                == [0x51, 0x82, 0x01, 0x12, 0xE5])
    }

    // MARK: - 降级路径（注入假函数指针；live 环境无法复现符号缺失）

    @Test func nilSymbolsDegradeWholeDomainSilently() {
        let client = DDCClient(symbols: nil)  // dlsym 失败的等价注入
        #expect(!client.isAvailable)
        #expect(client.discoverDisplays().isEmpty)
        #expect(client.readBrightness(of: DDCDisplay(id: 1)) == nil)
        #expect(!client.writeBrightness(50, to: DDCDisplay(id: 1)))
        #expect(!client.writeContrast(50, to: DDCDisplay(id: 1)))
    }

    @Test func fakePointerCreateFailureDegradesPerCall() {
        // create 恒 nil：内建屏/受限环境的真实形态——可用但逐次降级
        let fake = IOAVServiceSymbols(
            create: { _ in nil },
            readI2C: { _, _, _, _, _ in KERN_FAILURE },
            writeI2C: { _, _, _, _, _ in KERN_FAILURE },
            release: { _ in })
        let client = DDCClient(symbols: fake)
        #expect(client.isAvailable)
        #expect(client.discoverDisplays().isEmpty)
        #expect(client.readBrightness(of: DDCDisplay(id: 2)) == nil)
        #expect(!client.writeBrightness(80, to: DDCDisplay(id: 2)))
        #expect(!client.writeContrast(30, to: DDCDisplay(id: 2)))
    }

    @Test func fakePointerFullPipelineNeverCrashes() {
        // create 成功但 I2C 全失败：管道全走通也不崩（AVService 的释放由符号表接管）
        let fake = IOAVServiceSymbols(
            create: { _ in OpaquePointer(bitPattern: 1) },
            readI2C: { _, _, _, _, _ in KERN_FAILURE },
            writeI2C: { _, _, _, _, _ in KERN_FAILURE },
            release: { _ in })
        let client = DDCClient(symbols: fake)
        // 无真实显示器匹配的环境（CI）：管道在服务匹配层就降级返回
        _ = client.discoverDisplays()
        #expect(client.readBrightness(of: DDCDisplay(id: 0xDEAD)) == nil)
        #expect(!client.writeBrightness(10, to: DDCDisplay(id: 0xDEAD)))
    }

    // MARK: - 渐变序列

    @Test func rampSequenceIsMonotonicWithExactStepCount() {
        let up = BrightnessRamp(from: 20, to: 80, steps: 13, stepDelayMilliseconds: 40)
        let upSeq = up.sequence()
        #expect(upSeq.count == 13)
        #expect(upSeq.first == 20)
        #expect(upSeq.last == 80)
        #expect(zip(upSeq, upSeq.dropFirst()).allSatisfy { $0 <= $1 })

        let down = BrightnessRamp(from: 80, to: 20, steps: 7, stepDelayMilliseconds: 30)
        let downSeq = down.sequence()
        #expect(downSeq.count == 7)
        #expect(downSeq.first == 80)
        #expect(downSeq.last == 20)
        #expect(zip(downSeq, downSeq.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func rampDegenerateAndOutOfDomainInputsConverge() {
        #expect(BrightnessRamp(from: 10, to: 90, steps: 1, stepDelayMilliseconds: 10).sequence() == [90])
        #expect(BrightnessRamp(from: 10, to: 90, steps: 0, stepDelayMilliseconds: 10).sequence().isEmpty)
        #expect(BrightnessRamp(from: 10, to: 90, steps: -3, stepDelayMilliseconds: 10).sequence().isEmpty)
        // 越界端点经 clamp 出口收敛后等差
        #expect(BrightnessRamp(from: 120, to: -5, steps: 3, stepDelayMilliseconds: 10).sequence()
                == [100, 50, 0])
        // from == to：恒定序列
        #expect(BrightnessRamp(from: 42, to: 42, steps: 5, stepDelayMilliseconds: 10).sequence()
                == Array(repeating: 42, count: 5))
    }

    // MARK: - 昼夜规则

    @Test func daylightRuleSwitchesAtSixAndEighteenBoundaries() {
        let rule = DaylightBrightnessRule(dayValue: 80, nightValue: 20, sunriseAt: 6, sunsetAt: 18)
        #expect(rule.value(at: 0) == 20)
        #expect(rule.value(at: 5.99) == 20)
        #expect(rule.value(at: 6) == 80)  // 日出时刻即切日间（含端点）
        #expect(rule.value(at: 12) == 80)
        #expect(rule.value(at: 17.99) == 80)
        #expect(rule.value(at: 18) == 20)  // 日落时刻即切夜间（右开区间）
        #expect(rule.value(at: 23.99) == 20)
    }

    @Test func daylightRuleHandlesPolarNightAndMidnightSun() {
        // 极夜：sunrise == sunset，日间窗口为空 → 全天夜间
        let polarNight = DaylightBrightnessRule(dayValue: 90, nightValue: 15, sunriseAt: 12, sunsetAt: 12)
        for hour in [0.0, 6, 11.99, 12, 12.01, 18, 23.99] {
            #expect(polarNight.value(at: hour) == 15)
        }
        // 极昼：sunrise 0 / sunset 24 → 全天日间
        let midnightSun = DaylightBrightnessRule(dayValue: 90, nightValue: 15, sunriseAt: 0, sunsetAt: 24)
        for hour in [0.0, 6, 12, 23.99] {
            #expect(midnightSun.value(at: hour) == 90)
        }
        // 倒挂（sunrise > sunset）：按极夜处理——宁暗勿闪
        let inverted = DaylightBrightnessRule(dayValue: 90, nightValue: 15, sunriseAt: 20, sunsetAt: 8)
        for hour in [0.0, 6, 12, 23.99] {
            #expect(inverted.value(at: hour) == 15)
        }
    }

    @Test func daylightRuleClampsDirtyConfiguration() {
        let rule = DaylightBrightnessRule(dayValue: 130, nightValue: -7, sunriseAt: 6, sunsetAt: 18)
        #expect(rule.value(at: 10) == 100)
        #expect(rule.value(at: 22) == 0)
    }

    // MARK: - live 冒烟（容错）

    @Test func liveDiscoverySmokeToleratesDisplaylessHosts() {
        let client = DDCClient()  // 真实 dlopen/dlsym 路线
        #expect(client.isAvailable)  // 当前 macOS IOKit 均导出三符号；缺失即本用例失败暴露
        let displays = client.discoverDisplays()
        // CI/无屏沙盒环境返回空是合法降级；有屏环境只验证可枚举 + id 唯一
        #expect(Set(displays.map(\.id)).count == displays.count)
        if let first = displays.first {
            // 读失败（显示器不支持 DDC/CI）返回 nil 属预期，不据此判失败
            _ = client.readBrightness(of: first)
        }
    }
}
