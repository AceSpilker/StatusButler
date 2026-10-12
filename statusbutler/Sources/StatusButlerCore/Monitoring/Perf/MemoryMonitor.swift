import Foundation

// MARK: - 模型（T-027）

public struct MemoryUsage: Sendable, Equatable {
    public let totalBytes: UInt64
    /// 已用口径 = active + wired + compressed（活动窗口视角，与活动监视器"已用"最接近）。
    /// inactive/speculative 是可回收缓存，不计入已用——"剩余多少"看 free+可回收才有意义。
    public let usedBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        freeBytes: UInt64,
        swapUsedBytes: UInt64
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
    }
}

/// mach_vm_statistics64 的值类型化（页计数 + 页大小），让换算可喂固定值单测
public struct VMStatisticsValues: Sendable, Equatable {
    public var activePages: UInt64
    public var wiredPages: UInt64
    public var compressedPages: UInt64
    public var freePages: UInt64
    public var pageSize: UInt64

    public init(
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        freePages: UInt64,
        pageSize: UInt64
    ) {
        self.activePages = activePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.freePages = freePages
        self.pageSize = pageSize
    }
}

// MARK: - 监控器

/// 内存一次性采样器：host_statistics64(HOST_VM_INFO64) + hw.memsize + vm.swapusage。
/// 单次读取即可成型（无差分），只在被调用时执行一次——A7"有人看才采样"。
public struct MemoryMonitor: Sendable {
    public init() {}

    public func read() async -> MemoryUsage? {
        // 阻塞 sysctl/mach 调用收敛在 nonisolated static；read() 只编排
        Self.readSync()
    }

    nonisolated static func readSync() -> MemoryUsage? {
        guard let stats = sampleVMStatistics(),
              let total = totalPhysicalBytes()
        else { return nil }
        let swap = swapUsedBytes() ?? 0  // swap 拿不到不算失败：总量与分区仍有效
        return usage(stats: stats, totalBytes: total, swapUsedBytes: swap)
    }

    // MARK: - 纯函数（单测入口）

    /// 页计数 → 字节换算与 used 口径的唯一收口：
    /// used = (active + wired + compressed) × pageSize
    public static func usage(
        stats: VMStatisticsValues,
        totalBytes: UInt64,
        swapUsedBytes: UInt64
    ) -> MemoryUsage {
        let active = stats.activePages * stats.pageSize
        let wired = stats.wiredPages * stats.pageSize
        let compressed = stats.compressedPages * stats.pageSize
        let free = stats.freePages * stats.pageSize
        return MemoryUsage(
            totalBytes: totalBytes,
            usedBytes: active + wired + compressed,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            swapUsedBytes: swapUsedBytes
        )
    }

    /// 解析 vm.swapusage 文本（形如 "total = 1024.00M  used = 1.50M  free = …"）中的 used。
    /// 该 sysctl 只输出人类可读字符串，单位 K/M/G/T 随系统版本浮动，故解析独立成纯函数。
    public static func parseSwapUsedBytes(_ raw: String) -> UInt64? {
        guard let range = raw.range(of: "used = ") else { return nil }
        let token = raw[range.upperBound...].prefix { !$0.isWhitespace }
        guard !token.isEmpty, let last = token.last else { return nil }
        let unit: Double
        var numberPart = token
        switch last {
        case "K": unit = 1024
        case "M": unit = 1024 * 1024
        case "G": unit = 1024 * 1024 * 1024
        case "T": unit = 1024.0 * 1024 * 1024 * 1024
        default:
            // 理论上总有单位字母；没有就当裸字节数
            unit = 1
        }
        if unit != 1 { numberPart = token.dropLast() }
        guard let value = Double(numberPart) else { return nil }
        return UInt64((value * unit).rounded())
    }

    // MARK: - 系统读取

    nonisolated static func sampleVMStatistics() -> VMStatisticsValues? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<Int32>.stride
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) { int32Pointer in
                host_statistics64(host, HOST_VM_INFO64, int32Pointer, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // vm_statistics64 的计数单位是内核页（Apple Silicon 16K / Intel 4K），不能写死 4096。
        // vm_kernel_page_size 全局 var 在 Swift 6 下并发不安全，走 sysctl 拿同值
        guard let pageSize = kernelPageSize() else { return nil }
        return VMStatisticsValues(
            activePages: UInt64(stats.active_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            freePages: UInt64(stats.free_count),
            pageSize: pageSize
        )
    }

    nonisolated static func kernelPageSize() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        guard sysctlbyname("hw.pagesize", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }

    nonisolated static func totalPhysicalBytes() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }

    nonisolated static func swapUsedBytes() -> UInt64? {
        var size = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buffer, &size, nil, 0) == 0 else { return nil }
        // 指针版 init(cString:) 未被弃用（数组版已弃用）；缓冲区带 NUL 终止
        let text = buffer.withUnsafeBufferPointer { pointer -> String in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        return parseSwapUsedBytes(text)
    }
}
