import Foundation
import Testing
@testable import StatusButlerCore

// T-025: 解码纯函数固定字节断言 + SMC 布局钉死 + live 冒烟（无 SMC 机器上 nil 也是通过态）
@Suite struct ThermalMonitorTests {
    // MARK: - 解码纯函数

    @Test func fpe2DecodesAsBigEndianUInt16() {
        // 任务口径：UInt16 大端，[0x0A,0x00] → 2560
        #expect(ThermalMonitor.decodeFPE2([0x0A, 0x00]) == 2560)
        #expect(ThermalMonitor.decodeFPE2([0x00, 0x64]) == 100)
        #expect(ThermalMonitor.decodeFPE2([0xFF, 0xFF]) == 65535)
        #expect(ThermalMonitor.decodeFPE2([0x01]) == nil)
        #expect(ThermalMonitor.decodeFPE2([]) == nil)
    }

    @Test func fltDecodesNativeEndianFloats() {
        // 25.5°C 的 IEEE754 单精度位型 0x41CC0000；本机序（小端）字节序 00 00 CC 41。
        // arm64 真机探测证明 SMC flt 按本机序存储（F0Mn/F0Mx 出厂整值 1000/4900
        // 只在本机序解读下成立），旧文档的"大端"说法不可靠；与 stats 的 Float.load 同口径
        #expect(ThermalMonitor.decodeFLT([0x00, 0x00, 0xCC, 0x41]) == 25.5)
        #expect(ThermalMonitor.decodeFLT([0x00, 0x00, 0xC8, 0xC2]) == -100.0)
        #expect(ThermalMonitor.decodeFLT([0x00, 0x00, 0xC0, 0x7F]) == nil)  // NaN → 不可用
        #expect(ThermalMonitor.decodeFLT([0x00, 0x00]) == nil)
    }

    @Test func spuiDecodesBigEndianUInt32() {
        #expect(ThermalMonitor.decodeSPUI([0x00, 0x00, 0x0E, 0xD0]) == 3792)
        #expect(ThermalMonitor.decodeSPUI([0xFF, 0xFF, 0xFF, 0xFF]) == 0xFFFF_FFFF)
        #expect(ThermalMonitor.decodeSPUI([0x01]) == nil)
    }

    @Test func sp78DecodesSignedFixedPoint() {
        #expect(ThermalMonitor.decodeSP78([0x32, 0x00]) == 50.0)
        #expect(ThermalMonitor.decodeSP78([0x19, 0x80]) == 25.5)
        #expect(ThermalMonitor.decodeSP78([0x81, 0x00]) == -127.0)  // 故障哨兵字节型
        #expect(ThermalMonitor.decodeSP78([0x00]) == nil)
    }

    @Test func faultTemperaturesAreDropped() {
        // A5·TF-01：-127 等故障读数按不可用丢弃
        #expect(!ThermalMonitor.isPlausibleCelsius(-127))
        #expect(!ThermalMonitor.isPlausibleCelsius(200))
        #expect(!ThermalMonitor.isPlausibleCelsius(.nan))
        #expect(!ThermalMonitor.isPlausibleCelsius(.infinity))
        #expect(ThermalMonitor.isPlausibleCelsius(45.5))
        #expect(ThermalMonitor.isPlausibleCelsius(-10))  // 严寒户外不误杀
    }

    @Test func temperatureDecodeDispatchesByType() {
        // 本机序 flt（真机主路径）
        #expect(ThermalMonitor.decodeTemperature(type: "flt ", bytes: [0x00, 0x00, 0xCC, 0x41]) == 25.5)
        // 本机序解读为物理不可能值时退回大端解读（0x41CC0000 的另一阵营字节序）
        #expect(ThermalMonitor.decodeTemperature(type: "flt ", bytes: [0x41, 0xCC, 0x00, 0x00]) == 25.5)
        #expect(ThermalMonitor.decodeTemperature(type: "sp78", bytes: [0x32, 0x00]) == 50.0)
        // 未知类型不猜（A5：绝不显示假数据）
        #expect(ThermalMonitor.decodeTemperature(type: "ui8 ", bytes: [0x30]) == nil)
    }

    @Test func fanRPMDispatchesByType() {
        // flt（arm64 真机实测 F0Ac=1265.0 的本机序字节）
        #expect(ThermalMonitor.fanRPM(type: "flt ", bytes: [0x00, 0x20, 0x9E, 0x44]) == 1265)
        // fpe2：原始 BE16=4800 → RPM = 4800/4 = 1200（stats Int(fromFPE2:) 同源）
        #expect(ThermalMonitor.fanRPM(type: "fpe2", bytes: [0x12, 0xC0]) == 1200)
        #expect(ThermalMonitor.fanRPM(type: "ui8 ", bytes: [0x30]) == nil)
    }

    @Test func fanCountHandlesTypeVariants() {
        #expect(ThermalMonitor.fanCount(type: "ui8 ", bytes: [1]) == 1)  // arm64 真机 FNum 形态
        #expect(ThermalMonitor.fanCount(type: "fpe2", bytes: [0x00, 0x08]) == 2)  // 原始 8 ÷4
        #expect(ThermalMonitor.fanCount(type: "ui8 ", bytes: []) == nil)
        #expect(ThermalMonitor.fanCount(type: "ui8 ", bytes: nil) == nil)
    }

    // MARK: - fourcc 与 SMC 布局

    @Test func fourCharCodePacksBigEndian() {
        #expect("TC0P".fourCharCode == 0x54433050)
        #expect("fpe2".fourCharCode == 0x66706532)
        #expect("TOOLONG".fourCharCode == nil)  // 非 4 字符宁失败不猜
    }

    @Test func fourCCRoundTrips() {
        for s in ["TC0P", "fpe2", "sp78", "flt ", "FNum", "F0Ac"] {
            #expect(fourCCString(s.fourCharCode!) == s)
        }
    }

    @Test func smcParamStructLayoutIsPinned() {
        // 与内核约定的 80 字节布局（经典 64 字节版会被新内核 kIOReturnBadArgument 拒绝，
        // macOS 26 arm64 真机实测）。Swift 改布局策略时这里先红
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
        #expect(MemoryLayout<SMCParamStruct>.alignment == 4)
        #expect(MemoryLayout<SMCParamStruct>.size == MemoryLayout<SMCParamStruct>.stride)
    }

    // MARK: - 快照模型

    @Test func candidateTableMatchesSpec() {
        #expect(ThermalMonitor.temperatureKeyCandidates.map(\.key)
            == ["TC0P", "TC0D", "TG0P", "TG0D", "TB1T", "TB2T", "TM0P", "Ts0S", "TA0P"])
    }

    @Test func maxCelsiusTracksSensorMax() {
        let snapshot = ThermalSnapshot(
            fans: [FanReading(id: 0, minRPM: 1200, maxRPM: 5400, currentRPM: 1900)],
            sensors: [
                SensorReading(key: "TC0P", name: "CPU 附近", celsius: 80),
                SensorReading(key: "TB1T", name: nil, celsius: 30),
            ]
        )
        #expect(snapshot.maxCelsius == 80)
        #expect(ThermalSnapshot(fans: [], sensors: []).maxCelsius == nil)
        // 快照相等性（渲染缓存 key 根基）不被计算属性干扰
        #expect(snapshot != ThermalSnapshot(fans: [], sensors: []))
        #expect(ThermalSnapshot(fans: [], sensors: []) == ThermalSnapshot(fans: [], sensors: []))
    }

    // MARK: - live 冒烟（只验不变量/可选性；无 SMC 的机器上 read()==nil 是设计内降级）

    @Test func liveReadProducesConsistentSnapshotOrNull() async {
        let snapshot = await ThermalMonitor().read()
        guard let snapshot else { return }  // 虚拟机/无 AppleSMC：整体 nil，允许通过
        for fan in snapshot.fans {
            #expect(fan.id >= 0)
            #expect(fan.maxRPM >= fan.minRPM)
            #expect(fan.currentRPM >= 0)
        }
        for sensor in snapshot.sensors {
            #expect(ThermalMonitor.isPlausibleCelsius(sensor.celsius))
        }
        if let max = snapshot.maxCelsius {
            #expect(snapshot.sensors.contains { $0.celsius == max })
        }
    }

    @Test func liveSMCClientReadsFNumOrNull() {
        let client = SMCClient()
        guard client.open() else { return }
        defer { client.close() }
        // 打得开就一定读得出 FNum（风扇数键全机型存在；0 风扇机型返回空数组字节也是成功）
        let value = client.readValue(key: "FNum")
        #expect(value != nil)
        #expect(value?.bytes.isEmpty == false)
    }
}
