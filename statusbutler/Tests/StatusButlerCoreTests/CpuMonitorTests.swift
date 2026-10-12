import Foundation
import Testing
@testable import StatusButlerCore

// T-027: CPU tick 差分纯函数（固定序列手算断言）+ live 冒烟
@Suite struct CpuMonitorTests {
    @Test func identicalTicksMeanZeroUsage() {
        // idle 无变化（全字段无变化）→ 0%
        let ticks: [CoreTicks] = [
            (user: 100, system: 50, idle: 1000, nice: 10),
            (user: 5, system: 0, idle: 500, nice: 0),
        ]
        let result = CpuMonitor.usage(prev: ticks, curr: ticks)
        #expect(result.total == 0)
        #expect(result.perCore == [0, 0])
    }

    @Test func fullyBusyDeltaHits100() {
        // 新增 tick 全部落在 user（idle 不变）→ 100%
        let prev: [CoreTicks] = [(user: 10, system: 0, idle: 90, nice: 0)]
        let curr: [CoreTicks] = [(user: 110, system: 0, idle: 90, nice: 0)]
        let result = CpuMonitor.usage(prev: prev, curr: curr)
        #expect(result.total == 100)
        #expect(result.perCore == [100])
    }

    @Test func mixedDeltasMatchHandComputation() {
        // 手算：核0 Δuser=10, Δidle=30 → 10/40 = 25%；核1 Δuser=20, Δsystem=20, Δidle=0 → 40/40 = 100%
        // 总 = (10+40)/(40+40) = 50/80 = 62.5%
        let prev: [CoreTicks] = [
            (user: 100, system: 0, idle: 100, nice: 0),
            (user: 100, system: 100, idle: 100, nice: 0),
        ]
        let curr: [CoreTicks] = [
            (user: 110, system: 0, idle: 130, nice: 0),
            (user: 120, system: 120, idle: 100, nice: 0),
        ]
        let result = CpuMonitor.usage(prev: prev, curr: curr)
        #expect(result.perCore[0] == 25)
        #expect(result.perCore[1] == 100)
        #expect(result.total == 62.5)
    }

    @Test func niceCountsAsBusy() {
        // nice tick 属于"有活干"，计入分子
        let prev: [CoreTicks] = [(user: 0, system: 0, idle: 100, nice: 0)]
        let curr: [CoreTicks] = [(user: 0, system: 0, idle: 100, nice: 50)]
        let result = CpuMonitor.usage(prev: prev, curr: curr)
        #expect(result.total == 100)
    }

    @Test func counterWrapSaturatesToZero() {
        // 计数回绕/重置（curr<prev）：饱和 0，不产生负值
        let prev: [CoreTicks] = [(user: 900, system: 0, idle: 100, nice: 0)]
        let curr: [CoreTicks] = [(user: 100, system: 0, idle: 200, nice: 0)]
        let result = CpuMonitor.usage(prev: prev, curr: curr)
        #expect(result.perCore == [0])
        #expect(result.total == 0)
    }

    @Test func mismatchedCountsZipSafely() {
        // 核心数变化（两次采样核数不同）：按 zip 收敛，不越界
        let prev: [CoreTicks] = [(user: 1, system: 0, idle: 1, nice: 0)]
        let curr: [CoreTicks] = [
            (user: 2, system: 0, idle: 1, nice: 0),
            (user: 9, system: 9, idle: 0, nice: 0),
        ]
        let result = CpuMonitor.usage(prev: prev, curr: curr)
        #expect(result.perCore == [100])
        #expect(result.total == 100)
    }

    @Test func emptyInputReturnsZero() {
        let result = CpuMonitor.usage(prev: [], curr: [])
        #expect(result.total == 0)
        #expect(result.perCore.isEmpty)
    }

    // MARK: - live 冒烟（只验类型/范围不变量，不断言具体占用值）

    @Test func liveReadReturnsBoundedUsageOrNull() async {
        guard let usage = await CpuMonitor().read() else { return }
        #expect(!usage.perCore.isEmpty)
        #expect(usage.totalPercent >= 0 && usage.totalPercent <= 100)
        for core in usage.perCore {
            #expect(core >= 0 && core <= 100)
        }
    }

    @Test func sampleTicksSeesAllCores() {
        // 与 sysctl 核数对照，确认 flavor 用对（PROCESSOR_CPU_LOAD_INFO 每核一条）
        guard let ticks = CpuMonitor.sampleTicks() else { return }
        var size = 0
        sysctlbyname("hw.ncpu", nil, &size, nil, 0)
        var ncpu = [Int32](repeating: 0, count: size / MemoryLayout<Int32>.stride)
        guard sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0) == 0, ncpu[0] > 0 else { return }
        #expect(ticks.count == Int(ncpu[0]))
    }
}
