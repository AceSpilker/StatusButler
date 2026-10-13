import Foundation
import IOKit

// T-218（E19）：磁盘 I/O 采样器 + 空间预警判据。
// 路线实测结论（macOS 26 arm64，2026-10，C 探针钉死）：
// 1. sysctl CTL_HW/HW_DISKSTATS：SDK 头文件留有常量（=9）但内核已不实现，
//    实测返回 ENOENT——死路，不可用。
// 2. host_statistics64：本 SDK 的 host flavor 表无任何磁盘项
//    （HOST_DISKLOAD_INFO 只存在于古早 macOS）——死路。
// 3. 实跑通的路（本文件采用）：IOServiceMatching("IOBlockStorageDriver") 遍历 +
//    IORegistryEntryCreateCFProperty 读公开头 IOBlockStorageDriver.h 钉死的
//    "Statistics"→"Bytes (Read)"/"Bytes (Write)" 累计字节计数器。每物理盘恰一个
//    driver（分区级 IOMedia 挂在 driver 之下、不另挂），各 driver 求和即全系统口径，
//    无重复计数。网络卷/虚拟卷稀有可能缺席属口径边界：宁少勿错算。
// 采样纪律（A7·3）：仅被调用时读两次各一次，150ms 差分窗口，无循环无定时器——
// "有人看才采样"。

// MARK: - 模型

public struct DiskIORates: Sendable, Equatable {
    public let readBytesPerSec: Double
    public let writeBytesPerSec: Double

    public init(readBytesPerSec: Double, writeBytesPerSec: Double) {
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
    }
}

// MARK: - 监控器协议（AGENTS：监控器全部协议化，测试注入假实现）

public protocol DiskIOMonitoring: Sendable {
    func read() async -> DiskIORates?
}

// MARK: - 监控器

/// 磁盘 I/O 一次性采样器：全系统块设备累计字节计数器两次差分 ÷ 真实时钟间隔。
public struct DiskIOMonitor: Sendable {
    /// 差分窗口：SSD 计数器粒度足够细，150ms 与 GPU 窗口同档（并行不拖节拍）
    public static let sampleWindow: Duration = .milliseconds(150)

    public init() {}

    public func read() async -> DiskIORates? {
        guard let prev = Self.diskCounters() else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        try? await Task.sleep(for: Self.sampleWindow, tolerance: Self.sampleWindow / 5)
        // 真实流逝时间做分母：sleep 被取消/调度延迟时速率仍正确（NetRateMonitor 同源纪律）
        let interval = Self.seconds(from: clock.now - start)
        guard let curr = Self.diskCounters() else { return nil }
        return Self.rates(prev: prev, curr: curr, interval: interval)
    }

    // MARK: - 纯函数（单测入口）

    /// 计数器差分 → 速率。间隔 ≤ 0 防除零按 0 处理；
    /// 计数回绕/驱动窗口内消失（curr<prev）饱和为 0，不产生负速率。
    public static func rates(
        prev: (read: UInt64, write: UInt64),
        curr: (read: UInt64, write: UInt64),
        interval: TimeInterval
    ) -> DiskIORates {
        guard interval > 0 else { return DiskIORates(readBytesPerSec: 0, writeBytesPerSec: 0) }
        let deltaRead = curr.read >= prev.read ? Double(curr.read - prev.read) : 0
        let deltaWrite = curr.write >= prev.write ? Double(curr.write - prev.write) : 0
        return DiskIORates(readBytesPerSec: deltaRead / interval, writeBytesPerSec: deltaWrite / interval)
    }

    /// 各 driver 计数求和：缺键的驱动整条跳过（宁少勿错算）；空列表 = 0/0 合法值
    /// （无块设备的极端虚拟机）而非 nil。求和带溢出饱和——坏驱动返回的巨型数
    /// 至多污染到 UInt64.max，不产生回绕小值假象。
    public static func sum(services: [(read: UInt64?, write: UInt64?)]) -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        for service in services {
            if let r = service.read {
                let (added, overflow) = read.addingReportingOverflow(r)
                read = overflow ? .max : added
            }
            if let w = service.write {
                let (added, overflow) = write.addingReportingOverflow(w)
                write = overflow ? .max : added
            }
        }
        return (read, write)
    }

    /// 抖动间隔 → 秒（Duration 跨平台分量换算，各 Perf monitor 同源）
    static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: - 系统读取

    /// 一次抓全系统块设备累计字节计数器（阻塞 IOKit 调用收敛于此，read() 只编排）。
    /// 迭代失败才 nil（IOKit 出错）；枚举到零个 driver 时返回 0/0（合法零流量）。
    static func diskCounters() -> (read: UInt64, write: UInt64)? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }  // matching dictionary 已被 consume，迭代器引用要还

        var services: [(read: UInt64?, write: UInt64?)] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            services.append(Self.serviceCounters(service))
        }
        return sum(services: services)
    }

    /// 单个 driver 的 Statistics 表 → 读写字节计数。键名钉死于公开头
    /// IOBlockStorageDriver.h（kIOBlockStorageDriverStatisticsKey 一族）。
    private static func serviceCounters(_ service: io_service_t) -> (read: UInt64?, write: UInt64?) {
        guard let statistics = IORegistryEntryCreateCFProperty(
            service, "Statistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        return (
            statistics["Bytes (Read)"].flatMap(counter),
            statistics["Bytes (Write)"].flatMap(counter)
        )
    }

    /// 注册表数值 → 计数器：非 NSNumber/负数拒收（uint64Value 对负数回绕会毒化总和）。
    private static func counter(_ value: Any) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else { return nil }
        return number.uint64Value
    }

    // MARK: - 空间预警（E19；通知接线归 T-215 通道）

    /// 预警默认阈值：剩余 < 10 GiB 触发（UI 可设置化后由设置覆写，此为出厂缺省）
    public static let defaultWarnThresholdBytes: UInt64 = 10 * 1 << 30

    /// 根卷空间：total = 卷总容量，free = 重要用途可用容量（系统清理后的真实可用
    /// 口径，比物理空闲块保守）。URL resourceValues 为公开 API。读取失败或口径
    /// 缺失 → nil（降级不抛错，不拿别的口径冒充）。
    public static func diskFreeBytes(
        volumeURL: URL = URL(fileURLWithPath: "/")
    ) -> (total: UInt64, free: UInt64)? {
        guard let values = try? volumeURL.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        guard let total = values.volumeTotalCapacity, total >= 0,
              let available = values.volumeAvailableCapacityForImportantUsage, available >= 0
        else { return nil }
        return (UInt64(total), UInt64(available))
    }

    /// 预警判据：剩余"严格小于"阈值才报——等于阈值即恰好达标，不骚扰边界值。
    public static func shouldWarn(free: UInt64, threshold: UInt64) -> Bool {
        free < threshold
    }
}

extension DiskIOMonitor: DiskIOMonitoring {}
