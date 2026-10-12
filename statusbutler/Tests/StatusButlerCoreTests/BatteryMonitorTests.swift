import IOKit.ps
import Testing
@testable import StatusButlerCore

// T-020: IOPS 描述字典 → BatteryState 纯映射（假字典注入；live IOKit 读取只在冒烟里碰）
@Suite struct BatteryMonitorTests {
    @Test func mapsChargingBattery() {
        let state = BatteryMonitor.state(from: [
            kIOPSTypeKey: kIOPSBatteryPowerValue,
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 88,
            kIOPSIsChargingKey: true
        ])
        #expect(state == .battery(level: 88, charging: true))
    }

    @Test func mapsDischargingBatteryAndDefaultsChargingFalse() {
        let state = BatteryMonitor.state(from: [
            kIOPSCurrentCapacityKey: 12
            // 缺 Is Charging 键：默认未充电，而不是不可用
        ])
        #expect(state == .battery(level: 12, charging: false))
    }

    @Test func missingCapacityKeyIsUnavailable() {
        #expect(BatteryMonitor.state(from: [:]) == .unavailable)
        // 台式 Mac 的 "AC Power" 源：有名字无容量
        #expect(BatteryMonitor.state(from: [kIOPSNameKey: "AC Power"]) == .unavailable)
    }

    @Test func clampsOverflowCapacityTo100() {
        let state = BatteryMonitor.state(from: [
            kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 150
        ])
        #expect(state == .battery(level: 100, charging: false))
    }

    @Test func clampsNegativeCapacityTo0() {
        let state = BatteryMonitor.state(from: [
            kIOPSCurrentCapacityKey: -5
        ])
        #expect(state == .battery(level: 0, charging: false))
    }

    @Test func absentBatteryIsUnavailable() {
        let state = BatteryMonitor.state(from: [
            kIOPSIsPresentKey: false,
            kIOPSCurrentCapacityKey: 66,
            kIOPSIsChargingKey: true
        ])
        #expect(state == .unavailable)
    }

    @Test func liveReadSmoke() async {
        // CI/台式机可能无电池（.unavailable 合法）；有电池则百分比必须落在 0...100
        let state = await BatteryMonitor().read()
        if case .battery(let level, _) = state {
            #expect((0...100).contains(level))
        }
    }
}
