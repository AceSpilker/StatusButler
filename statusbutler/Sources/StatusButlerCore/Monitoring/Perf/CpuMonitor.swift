import Foundation

// MARK: - 模型（T-027）

public struct CpuUsage: Sendable, Equatable {
    public let totalPercent: Double
    public let perCore: [Double]  // 与逻辑核心一一对应；P/E 核分组属映射层（A7·PF-10）

    public init(totalPercent: Double, perCore: [Double]) {
        self.totalPercent = totalPercent
        self.perCore = perCore
    }
}

/// 单核 tick 四元组（mach processor_cpu_load_info 的值类型化）
public typealias CoreTicks = (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)

// MARK: - 监控器

/// CPU 占用率一次性采样器：两次 host_processor_info tick 差分。
/// 采样纪律（A7·3）：仅被调用时采样两次各一次，内部 100ms 窗口，无循环无定时器。
public struct CpuMonitor: Sendable {
    /// 差分窗口：tick 分辨率 10ms 级，100ms 足够累积又不拖慢调用方
    public static let sampleWindow: Duration = .milliseconds(100)

    public init() {}

    public func read() async -> CpuUsage? {
        guard let prev = Self.sampleTicks() else { return nil }
        try? await Task.sleep(for: Self.sampleWindow)
        guard let curr = Self.sampleTicks() else { return nil }
        let usage = Self.usage(prev: prev, curr: curr)
        return CpuUsage(totalPercent: usage.total, perCore: usage.perCore)
    }

    // MARK: - 纯函数（单测入口）

    /// tick 差分 → 占用%（占用 = 非空闲 tick / 全部 tick，无需挂钟时间）。
    /// 分母为 0（窗口内无 tick）按 0% 处理；计数回绕/核心数变化导致 curr<prev 饱和为 0，
    /// 绝不产生负值或除零。
    public static func usage(
        prev: [CoreTicks],
        curr: [CoreTicks]
    ) -> (total: Double, perCore: [Double]) {
        guard !prev.isEmpty else { return (0, []) }
        var perCore: [Double] = []
        perCore.reserveCapacity(min(prev.count, curr.count))
        var nonIdle: UInt64 = 0
        var all: UInt64 = 0
        for (p, c) in zip(prev, curr) {
            let dUser = delta(c.user, p.user)
            let dSystem = delta(c.system, p.system)
            let dNice = delta(c.nice, p.nice)
            let dIdle = delta(c.idle, p.idle)
            let coreAll = dUser + dSystem + dNice + dIdle
            let coreNonIdle = dUser + dSystem + dNice
            perCore.append(coreAll == 0 ? 0 : Double(coreNonIdle) / Double(coreAll) * 100)
            nonIdle += coreNonIdle
            all += coreAll
        }
        let total = all == 0 ? 0 : Double(nonIdle) / Double(all) * 100
        return (total, perCore)
    }

    private static func delta(_ curr: UInt64, _ prev: UInt64) -> UInt64 {
        curr >= prev ? curr - prev : 0
    }

    // MARK: - 系统读取

    /// 单次抓取每核 tick。阻塞 mach 调用收敛于此（Swift 6 并发边界），read() 只编排。
    /// 注意 flavor 是 PROCESSOR_CPU_LOAD_INFO（每核数组）——HOST_CPU_LOAD_INFO 只有全机聚合。
    nonisolated static func sampleTicks() -> [CoreTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = host_processor_info(
            host,
            processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
            &processorCount,
            &info,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info, processorCount > 0 else { return nil }
        defer {
            // mach 分配的缓冲区必须 vm_deallocate，否则每次采样泄漏
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let stateUser = Int(CPU_STATE_USER)
        let stateSystem = Int(CPU_STATE_SYSTEM)
        let stateIdle = Int(CPU_STATE_IDLE)
        let stateNice = Int(CPU_STATE_NICE)
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for core in 0..<Int(processorCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append((
                user: UInt64(info[base + stateUser]),
                system: UInt64(info[base + stateSystem]),
                idle: UInt64(info[base + stateIdle]),
                nice: UInt64(info[base + stateNice])
            ))
        }
        return ticks
    }
}
