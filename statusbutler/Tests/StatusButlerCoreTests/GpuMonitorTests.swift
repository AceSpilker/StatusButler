import Foundation
import Testing
@testable import StatusButlerCore

// T-203 测试：GpuUsage 相等语义与双 nil 安全值、PF-30 回退决策四态、驻留/单位纯函数、
// PerfSample 默认值兼容（不破既有构造）、引擎 GPU 域集成（假 monitor 注入）、PerfFeed 透传、
// live 冒烟（本机走真实 IOReport 只断言不崩与数值形态；CI headless 双 nil 同样通过）。

// MARK: - 测试基建

/// 线程安全 GPU 源（GpuMonitoring 假实现，可注入固定帧或失败）
final class CountingGpu: GpuMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let usage: GpuUsage?

    init(usage: GpuUsage?) { self.usage = usage }

    func read() async -> GpuUsage? {
        lock.withLock { calls += 1 }
        return usage
    }

    var callCount: Int { lock.withLock { calls } }
}

// MARK: - GpuUsage 相等语义

@Suite struct GpuUsageTests {

    @Test func equalityMatchesFieldSemantics() {
        #expect(GpuUsage(activePercent: 42.5, powerMilliwatts: 1200) == GpuUsage(activePercent: 42.5, powerMilliwatts: 1200))
        #expect(GpuUsage(activePercent: 42.5, powerMilliwatts: 1200) != GpuUsage(activePercent: 42.6, powerMilliwatts: 1200))
        #expect(GpuUsage(activePercent: 42.5, powerMilliwatts: 1200) != GpuUsage(activePercent: 42.5, powerMilliwatts: 1201))
        // nil 与 0 语义不同：nil=通道不可得（回退链降级），0=测得零负载——面板文案分流靠它
        #expect(GpuUsage(activePercent: nil, powerMilliwatts: nil) != GpuUsage(activePercent: 0, powerMilliwatts: 0))
        #expect(GpuUsage(activePercent: nil, powerMilliwatts: 500) == GpuUsage(activePercent: nil, powerMilliwatts: 500))
    }

    @Test func doubleNilIsASafeDistinctValue() {
        let headless = GpuUsage(activePercent: nil, powerMilliwatts: nil)
        #expect(headless.activePercent == nil)
        #expect(headless.powerMilliwatts == nil)
        #expect(headless == GpuUsage())
        #expect(headless != GpuUsage(activePercent: 1, powerMilliwatts: nil))
        #expect(headless != GpuUsage(activePercent: nil, powerMilliwatts: 1))
    }
}

// MARK: - 回退决策与纯函数

@Suite struct GpuFallbackChainTests {

    @Test func resolveFallbackChainFourStates() {
        let reading = GpuRawReading(
            utilizationPercent: 40, energyDeltaMillijoules: 300, elapsedSeconds: 0.5
        )
        // 双有：util 与功耗都展示
        #expect(
            GpuMonitor.resolve(
                plan: GpuChannelPlan(utilizationAvailable: true, powerAvailable: true),
                reading: reading
            ) == GpuUsage(activePercent: 40, powerMilliwatts: 600)
        )
        // 仅 util：功耗读数再好也强制剥离（通道不可得不越权展示）
        #expect(
            GpuMonitor.resolve(
                plan: GpuChannelPlan(utilizationAvailable: true, powerAvailable: false),
                reading: reading
            ) == GpuUsage(activePercent: 40, powerMilliwatts: nil)
        )
        // 仅 power：活跃度代理
        #expect(
            GpuMonitor.resolve(
                plan: GpuChannelPlan(utilizationAvailable: false, powerAvailable: true),
                reading: reading
            ) == GpuUsage(activePercent: nil, powerMilliwatts: 600)
        )
        // 双无：headless/虚拟机安全值
        #expect(
            GpuMonitor.resolve(
                plan: GpuChannelPlan(utilizationAvailable: false, powerAvailable: false),
                reading: reading
            ) == GpuUsage(activePercent: nil, powerMilliwatts: nil)
        )
    }

    @Test func resolveDropsInvalidReadings() {
        let both = GpuChannelPlan(utilizationAvailable: true, powerAvailable: true)
        // NaN/负值功耗能量 → nil（不显示假数据）
        #expect(
            GpuMonitor.resolve(
                plan: both,
                reading: GpuRawReading(utilizationPercent: .nan, energyDeltaMillijoules: -5, elapsedSeconds: 1)
            ) == GpuUsage(activePercent: nil, powerMilliwatts: nil)
        )
        // 百分比轻微越界钳制到 100（驻留比四舍五入可越界，非假数据）
        #expect(
            GpuMonitor.resolve(
                plan: both,
                reading: GpuRawReading(utilizationPercent: 100.4, energyDeltaMillijoules: 10, elapsedSeconds: 1)
            ) == GpuUsage(activePercent: 100, powerMilliwatts: 10)
        )
        // 非正间隔：功耗除零防死 → nil
        #expect(
            GpuMonitor.resolve(
                plan: both,
                reading: GpuRawReading(utilizationPercent: 10, energyDeltaMillijoules: 10, elapsedSeconds: 0)
            ) == GpuUsage(activePercent: 10, powerMilliwatts: nil)
        )
    }

    @Test func activePercentFromResidencyStates() {
        // 本机 GPUPH 实测形态：OFF + P1..P15；活跃 = 非非活跃态
        let states: [(name: String, ticks: Int64)] = [
            ("OFF", 7_000_000), ("P1", 1_000_000), ("P3", 2_000_000)
        ]
        let percent = GpuMonitor.activePercent(states: states)
        #expect(percent != nil)
        #expect(abs((percent ?? -1) - 30.0) < 1e-9)
        // 大小写与空白容差（状态命名随代际浮动）
        let sloppy = GpuMonitor.activePercent(states: [(" off ", 100), ("P2", 300)])
        #expect(abs((sloppy ?? -1) - 75.0) < 1e-9)
        // 全程非活跃 → 0%（测得零负载，不是 nil）
        #expect(GpuMonitor.activePercent(states: [("OFF", 500), ("IDLE", 500)]) == 0)
    }

    @Test func activePercentZeroOrEmptyTotalIsNil() {
        #expect(GpuMonitor.activePercent(states: []) == nil, "空驻留表 → nil")
        #expect(GpuMonitor.activePercent(states: [("OFF", 0), ("P1", 0)]) == nil, "窗口内无 tick → nil")
    }

    @Test func millijoulesUnitTable() {
        #expect(abs((GpuMonitor.millijoules(value: 27, unitLabel: "mJ") ?? -1) - 27) < 1e-9)
        #expect(abs((GpuMonitor.millijoules(value: 1_000, unitLabel: "uJ") ?? -1) - 1) < 1e-9)
        #expect(abs((GpuMonitor.millijoules(value: 28_023_096, unitLabel: "nJ") ?? -1) - 28.023096) < 1e-6)
        #expect(abs((GpuMonitor.millijoules(value: 0.5, unitLabel: "J") ?? -1) - 500) < 1e-9)
        #expect(abs((GpuMonitor.millijoules(value: 27, unitLabel: " mJ ") ?? -1) - 27) < 1e-9)
        #expect(GpuMonitor.millijoules(value: 27, unitLabel: "W") == nil, "未知单位 → nil 不换算")
        #expect(GpuMonitor.millijoules(value: .nan, unitLabel: "mJ") == nil)
    }

    @Test func scalarPercentNanosecondRoute() {
        #expect(abs((GpuMonitor.scalarPercent(nanosecondsDelta: 0.25e9, elapsedSeconds: 1) ?? -1) - 25) < 1e-9)
        #expect(GpuMonitor.scalarPercent(nanosecondsDelta: -5, elapsedSeconds: 1) == nil)
        #expect(GpuMonitor.scalarPercent(nanosecondsDelta: 5, elapsedSeconds: 0) == nil)
        #expect(GpuMonitor.scalarPercent(nanosecondsDelta: .infinity, elapsedSeconds: 1) == nil)
    }

    @Test func channelPlanHasAnyChannel() {
        #expect(GpuChannelPlan(utilizationAvailable: true, powerAvailable: false).hasAnyChannel)
        #expect(GpuChannelPlan(utilizationAvailable: false, powerAvailable: true).hasAnyChannel)
        #expect(!GpuChannelPlan(utilizationAvailable: false, powerAvailable: false).hasAnyChannel)
    }
}

// MARK: - PerfSample 兼容与引擎集成

@Suite struct GpuEngineIntegrationTests {

    @Test func perfSampleLegacyInitDefaultsGpuNil() {
        // 既有构造（不带 gpu）必须原样可用——默认参数保证向后兼容
        let legacy = PerfSample(cpu: nil, memory: nil, net: NetRates(bytesInPerSec: 1, bytesOutPerSec: 2))
        #expect(legacy.gpu == nil)
        #expect(legacy.net == NetRates(bytesInPerSec: 1, bytesOutPerSec: 2))

        let withGpu = PerfSample(
            cpu: nil, memory: nil, net: nil, gpu: GpuUsage(activePercent: 7, powerMilliwatts: 55)
        )
        #expect(withGpu.gpu == GpuUsage(activePercent: 7, powerMilliwatts: 55))
    }

    @Test func perfSampleEqualityIncludesGpu() {
        let base = { PerfSample(cpu: nil, memory: nil, net: nil, gpu: nil) }
        #expect(base() == base())
        let withGpu = PerfSample(
            cpu: nil, memory: nil, net: nil, gpu: GpuUsage(activePercent: 7, powerMilliwatts: 55)
        )
        #expect(base() != withGpu, "GPU 帧变化应打破 removeDuplicates 静默")
        // 相等性仍不含 at（既有去重语义不因新域改变）
        let older = PerfSample(cpu: nil, memory: nil, net: nil, gpu: nil, at: Date(timeIntervalSince1970: 0))
        #expect(base() == older)
    }

    @Test func sampleOncePublishesGpuFrame() async {
        let bus = PerfBus()
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            gpu: CountingGpu(usage: GpuUsage(activePercent: 12.5, powerMilliwatts: 480)),
            bus: bus, interval: .seconds(1)
        )
        await engine.sampleOnce()
        #expect(bus.sample?.gpu == GpuUsage(activePercent: 12.5, powerMilliwatts: 480))
    }

    @Test func samplingLoopCarriesGpuDomain() async {
        let bus = PerfBus()
        let gpu = CountingGpu(usage: GpuUsage(activePercent: 5, powerMilliwatts: 60))
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            gpu: gpu, bus: bus, interval: .milliseconds(20)
        )
        await engine.start("test")
        let gotFrame = await waitUntil(timeout: 3) { bus.sample?.gpu?.activePercent == 5 }
        #expect(gotFrame, "采样循环应持续发布含 GPU 域的帧")
        #expect(gpu.callCount >= 1)
        await engine.stop("test")
    }

    @Test func gpuDomainFailureKeepsOtherDomainsSilent() async {
        let bus = PerfBus()
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            gpu: CountingGpu(usage: nil),  // GPU 域失败（读不出）
            bus: bus, interval: .seconds(1)
        )
        await engine.sampleOnce()
        #expect(bus.sample?.gpu == nil, "GPU 失败静默 nil，不拖垮整帧")
        #expect(bus.sample?.cpu?.totalPercent == 33, "其余域照常发布")
        #expect(bus.sample?.net?.bytesInPerSec == 2048)
        #expect(bus.sample?.memory != nil)
    }

    @Test @MainActor func perfFeedMirrorsGpuThroughBus() async {
        let feed = PerfFeed(bus: PerfBus())
        feed.apply(
            PerfSample(cpu: nil, memory: nil, net: nil, gpu: GpuUsage(activePercent: 41, powerMilliwatts: 900))
        )
        // receive(on: main) 异步落主线程：短轮询等镜像（CI 慢机容忍）
        for _ in 0..<200 where feed.sample?.gpu?.activePercent != 41 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(feed.sample?.gpu == GpuUsage(activePercent: 41, powerMilliwatts: 900))
    }
}

// MARK: - live 冒烟（CI 安全：headless 双 nil 也通过）

@Suite struct GpuLiveSmokeTests {

    @Test func liveProbeDoesNotCrashAndValuesWellFormed() async {
        // 本机（arm64 macOS 26）走真实 IOReport 系统级订阅；CI headless 无 GPU 通道
        // 时探测得空矩阵、安全返回双 nil——两态都通过，只断言不崩与数值形态。
        let usage = await GpuMonitor().read()
        // 诊断输出（不参与断言）：真机通道探测实测结论随测试日志留档
        print("[T-203 live] GpuMonitor().read() = \(String(describing: usage))")
        if let usage {
            if let percent = usage.activePercent {
                #expect(percent.isFinite && percent >= 0 && percent <= 100)
            }
            if let milliwatts = usage.powerMilliwatts {
                #expect(milliwatts.isFinite && milliwatts >= 0)
            }
        }
    }
}
