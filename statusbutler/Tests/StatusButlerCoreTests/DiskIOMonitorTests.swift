import Foundation
import Testing
@testable import StatusButlerCore

// T-218 测试：磁盘 I/O 差分速率纯函数（除零/回绕保护）、driver 求和（缺键跳过/
// 溢出饱和）、空间预警阈值边界、PerfSample 新字段默认兼容与等性、引擎磁盘域集成
// （假 monitor 注入 + 失败静默 nil）、live 冒烟（IOKit 枚举与真读，能力缺席时容忍降级）。

// MARK: - 测试基建

/// 线程安全磁盘源（DiskIOMonitoring 假实现，可注入固定帧或失败）
final class CountingDiskIO: DiskIOMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let rates: DiskIORates?

    init(rates: DiskIORates?) { self.rates = rates }

    func read() async -> DiskIORates? {
        lock.withLock { calls += 1 }
        return rates
    }

    var callCount: Int { lock.withLock { calls } }
}

// MARK: - 差分速率纯函数

@Suite struct DiskIORatesTests {

    @Test func knownDeltasProduceExactRates() {
        // Δread=3000B, Δwrite=1000B, 间隔 2s → 1500 / 500 B/s
        let rates = DiskIOMonitor.rates(
            prev: (read: 1000, write: 500), curr: (read: 4000, write: 1500), interval: 2
        )
        #expect(rates.readBytesPerSec == 1500)
        #expect(rates.writeBytesPerSec == 500)
    }

    @Test func fractionalIntervalDividesCorrectly() {
        // 150ms 真实窗口 Δ 300B → 2000 B/s（亚秒间隔是采样常态）
        let rates = DiskIOMonitor.rates(
            prev: (read: 0, write: 0), curr: (read: 300, write: 0), interval: 0.15
        )
        #expect(rates.readBytesPerSec == 2000)
        #expect(rates.writeBytesPerSec == 0)
    }

    @Test func zeroAndNegativeIntervalGuardDivisionByZero() {
        for interval: TimeInterval in [0, -0.5] {
            let rates = DiskIOMonitor.rates(
                prev: (read: 0, write: 0), curr: (read: 500, write: 500), interval: interval
            )
            #expect(rates.readBytesPerSec == 0)
            #expect(rates.writeBytesPerSec == 0)
        }
    }

    @Test func counterResetSaturatesToZero() {
        // 驱动卸载/计数回绕（curr<prev）→ 0，不产生负速率
        let rates = DiskIOMonitor.rates(
            prev: (read: 9000, write: 9000), curr: (read: 100, write: 100), interval: 1
        )
        #expect(rates.readBytesPerSec == 0)
        #expect(rates.writeBytesPerSec == 0)
    }

    @Test func durationConvertsToSeconds() {
        #expect(DiskIOMonitor.seconds(from: .seconds(2)) == 2)
        #expect(DiskIOMonitor.seconds(from: .milliseconds(150)) == 0.15)
    }
}

// MARK: - driver 求和

@Suite struct DiskCounterSumTests {

    @Test func sumSkipsIncompleteServices() {
        // 缺键的驱动整条跳过：宁少勿错算
        let totals = DiskIOMonitor.sum(
            services: [(read: nil, write: nil), (read: 100, write: 200), (read: 300, write: nil)]
        )
        #expect(totals.read == 400)
        #expect(totals.write == 200)
    }

    @Test func emptyServiceListIsLegalZeroNotNil() {
        // 无块设备的极端虚拟机：0/0 是合法零流量（nil 留给 IOKit 枚举失败）
        let totals = DiskIOMonitor.sum(services: [])
        #expect(totals == (read: 0, write: 0))
    }

    @Test func sumSaturatesOnOverflowInsteadOfWrapping() {
        // 坏驱动返回巨型数：饱和到 max，不回绕成小值假象
        let totals = DiskIOMonitor.sum(
            services: [(read: .max, write: 0), (read: 10, write: 0)]
        )
        #expect(totals.read == UInt64.max)
    }
}

// MARK: - 空间预警

@Suite struct DiskSpaceWarningTests {

    @Test func warnBoundaryIsStrictlyLessThanThreshold() {
        let threshold: UInt64 = 10 * 1 << 30
        #expect(!DiskIOMonitor.shouldWarn(free: threshold, threshold: threshold), "等于阈值 = 恰好达标")
        #expect(DiskIOMonitor.shouldWarn(free: threshold - 1, threshold: threshold))
        #expect(!DiskIOMonitor.shouldWarn(free: threshold + 1, threshold: threshold))
        // 阈值 0：free 永远不小于 0 → 永不预警（合法关闭态）
        #expect(!DiskIOMonitor.shouldWarn(free: 0, threshold: 0))
    }

    @Test func diskFreeBytesLiveSmoke() throws {
        // live 冒烟：根卷口径 sanity（总量 > 0、可用 ≤ 总量、口径为"重要用途可用"）
        guard let space = DiskIOMonitor.diskFreeBytes() else {
            // 能力缺席（极端沙盒）容忍降级——纯函数路径已有 fixture 覆盖
            print("diskFreeBytes 不可得：降级跳过 live 断言")
            return
        }
        #expect(space.total > 0)
        #expect(space.free <= space.total)
        #expect(space.free > 0)
    }
}

// MARK: - PerfSample 兼容与引擎集成

@Suite struct DiskEngineIntegrationTests {

    @Test func perfSampleLegacyInitDefaultsDiskIONil() {
        // 既有构造（不带 diskIO）必须原样可用——默认参数保证向后兼容
        let legacy = PerfSample(cpu: nil, memory: nil, net: NetRates(bytesInPerSec: 1, bytesOutPerSec: 2))
        #expect(legacy.diskIO == nil)
        #expect(legacy.gpu == nil)

        let withDisk = PerfSample(
            cpu: nil, memory: nil, net: nil,
            diskIO: DiskIORates(readBytesPerSec: 4096, writeBytesPerSec: 512)
        )
        #expect(withDisk.diskIO == DiskIORates(readBytesPerSec: 4096, writeBytesPerSec: 512))
    }

    @Test func perfSampleEqualityIncludesDiskIO() {
        let base = { PerfSample(cpu: nil, memory: nil, net: nil, gpu: nil, diskIO: nil) }
        #expect(base() == base())
        let withDisk = PerfSample(
            cpu: nil, memory: nil, net: nil,
            diskIO: DiskIORates(readBytesPerSec: 1, writeBytesPerSec: 1)
        )
        #expect(base() != withDisk, "磁盘帧变化应打破 removeDuplicates 静默")
        // 相等性仍不含 at（既有去重语义不因新域改变）
        let older = PerfSample(
            cpu: nil, memory: nil, net: nil, gpu: nil, diskIO: nil,
            at: Date(timeIntervalSince1970: 0)
        )
        #expect(base() == older)
    }

    @Test func sampleOncePublishesDiskIOFrame() async {
        let bus = PerfBus()
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            diskIO: CountingDiskIO(rates: DiskIORates(readBytesPerSec: 8192, writeBytesPerSec: 1024)),
            bus: bus, interval: .seconds(1)
        )
        await engine.sampleOnce()
        #expect(
            bus.sample?.diskIO == DiskIORates(readBytesPerSec: 8192, writeBytesPerSec: 1024)
        )
        #expect(bus.sample?.cpu?.totalPercent == 33, "既有域照常发布")
    }

    @Test func samplingLoopCarriesDiskIODomain() async {
        let bus = PerfBus()
        let disk = CountingDiskIO(rates: DiskIORates(readBytesPerSec: 2048, writeBytesPerSec: 256))
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            diskIO: disk, bus: bus, interval: .milliseconds(20)
        )
        await engine.start("test")
        let gotFrame = await waitUntil(timeout: 3) { bus.sample?.diskIO?.readBytesPerSec == 2048 }
        #expect(gotFrame, "采样循环应持续发布含磁盘域的帧")
        #expect(disk.callCount >= 1)
        await engine.stop("test")
    }

    @Test func diskDomainFailureKeepsOtherDomainsSilent() async {
        let bus = PerfBus()
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            diskIO: CountingDiskIO(rates: nil),  // IOKit 枚举失败/无块设备
            bus: bus, interval: .seconds(1)
        )
        await engine.sampleOnce()
        #expect(bus.sample?.diskIO == nil, "磁盘域失败静默 nil，不拖垮整帧")
        #expect(bus.sample?.cpu?.totalPercent == 33)
        #expect(bus.sample?.net?.bytesInPerSec == 2048)
        #expect(bus.sample?.memory != nil)
    }
}

// MARK: - live 冒烟（IOKit 真枚举；CI 无块设备能力时容忍降级）

@Suite struct DiskIOLiveSmokeTests {

    @Test func diskCountersEnumerateRealDrivers() throws {
        guard let counters = DiskIOMonitor.diskCounters() else {
            print("IOBlockStorageDriver 枚举不可得：降级跳过 live 断言")
            return
        }
        // 真机（2026-10 探针）：至少一个 driver，计数为开机以来累计、必然非零量级
        #expect(counters.read > 0 || counters.write > 0)
    }

    @Test func liveReadReturnsWellFormedRatesOrNil() async {
        let rates = await DiskIOMonitor().read()
        guard let rates else {
            print("磁盘差分读不可得：降级跳过 live 断言")
            return
        }
        #expect(rates.readBytesPerSec >= 0)
        #expect(rates.writeBytesPerSec >= 0)
    }
}
