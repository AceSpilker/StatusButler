import Foundation

// T-203 性能分区（C2 弹层区）：PerfSample 面板消费端支持——GPU 契约占位、
// CPU P/E 拓扑、内存压力档与性能四行（CPU/内存/网速/GPU）展示映射。
// 映射全部纯函数（AGENTS：映射层保持纯函数），View 只做渲染，测试喂固定值。

// MARK: - GPU 契约占位（T-203 并行协作纪律）

/// GPU 用量帧：activePercent 是主读数（M1/M2 GPU 平均活跃），powerMilliwatts 是
/// 功率近似（部分机型只有功率可读）。双 nil = 本帧没有 GPU 读数。
///
/// ⚠️ 合并纪律（弹层区 → 引擎区）：引擎分支正在 Monitoring/Perf/ 落地同名类型与
/// `PerfSample.gpu` 存储属性——**合并时以引擎侧定义为准**，删除本 struct 与下方
/// extension 占位（同名双存会直接编译报重声明，响亮失败不怕漏删）。
public struct GpuUsage: Equatable, Sendable {
    public let activePercent: Double?
    public let powerMilliwatts: Double?

    public init(activePercent: Double? = nil, powerMilliwatts: Double? = nil) {
        self.activePercent = activePercent
        self.powerMilliwatts = powerMilliwatts
    }
}

extension PerfSample {
    /// 契约占位：引擎存储属性落地前恒 nil（GPU 行因此隐藏，不显示假 0%）。
    /// ⚠️ 合并时删除——见 GpuUsage 的合并纪律注记
    public var gpu: GpuUsage? { nil }
}

// MARK: - CPU P/E 拓扑

/// CPU 核拓扑（P/E 核数）。mach 每核占用数组在 Apple Silicon 上 P 核在前、
/// E 核在后（hw.perflevel0/1 的枚举序即物理序），分组按前缀/后缀切片求均值。
public struct CpuCoreTopology: Equatable, Sendable {
    public let performanceCores: Int
    public let efficiencyCores: Int

    public init(performanceCores: Int, efficiencyCores: Int) {
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
    }

    /// sysctl 真实现（组合根注入用：`cpuTopologyProvider: { CpuCoreTopology.readLive() }`）。
    /// Intel/虚拟机没有 perflevel 键 → nil，面板只显示总%（诚实降级不猜分组）
    public static func readLive() -> CpuCoreTopology? {
        func coreCount(_ key: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.stride
            guard sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }
        guard let performance = coreCount("hw.perflevel0.logicalcpu") else { return nil }
        let efficiency = coreCount("hw.perflevel1.logicalcpu") ?? 0
        return CpuCoreTopology(performanceCores: performance, efficiencyCores: efficiency)
    }
}

// MARK: - 内存压力档

/// 内存压力三档（used/total 口径）：门限 70%/90%，语义对齐系统内存压力灯
/// （绿=宽裕 / 黄=偏高 / 红=紧张）。used 口径是 active+wired+compressed（见
/// MemoryMonitor），本来就是"活动窗口"视角，按它分档与体感一致
public enum MemoryPressureTier: Equatable, Sendable {
    case comfortable
    case elevated
    case critical

    public var displayName: String {
        switch self {
        case .comfortable: return "宽裕"
        case .elevated: return "偏高"
        case .critical: return "紧张"
        }
    }

    public static func tier(usedBytes: UInt64, totalBytes: UInt64) -> MemoryPressureTier? {
        guard totalBytes > 0 else { return nil }
        let ratio = Double(usedBytes) / Double(totalBytes)
        if ratio >= 0.9 { return .critical }
        if ratio >= 0.7 { return .elevated }
        return .comfortable
    }
}

// MARK: - 性能四行展示映射（纯函数）

public enum PerfPanelMapping {
    // MARK: CPU 行

    /// CPU 主值：总占用取整（一位小数在标题字号下读不清，取整是诚实取舍）
    public static func cpuValueText(_ cpu: CpuUsage?) -> String {
        guard let cpu else { return "—" }
        return "\(Int(cpu.totalPercent.rounded()))%"
    }

    /// P/E 分组文案："P 32% · E 8%"。推导失败（拓扑缺失 / P+E 与每核数不符 /
    /// 每核数组为空）返回 nil——调用方退回核数文案，绝不显示猜出来的分组
    public static func cpuGroupText(cpu: CpuUsage?, topology: CpuCoreTopology?) -> String? {
        guard let cpu, let topology, !cpu.perCore.isEmpty else { return nil }
        let pCount = topology.performanceCores
        let eCount = topology.efficiencyCores
        guard pCount >= 0, eCount >= 0, pCount + eCount == cpu.perCore.count else { return nil }
        func mean(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
        let pAverage = mean(Array(cpu.perCore.prefix(pCount)))
        let eAverage = mean(Array(cpu.perCore.suffix(eCount)))
        return "P \(Int(pAverage.rounded()))% · E \(Int(eAverage.rounded()))%"
    }

    /// CPU 副标题：分组优先 → 核数 → "CPU 不可用"
    public static func cpuSubtitleText(cpu: CpuUsage?, topology: CpuCoreTopology?) -> String {
        if let group = cpuGroupText(cpu: cpu, topology: topology) {
            return group
        }
        guard let cpu else { return "CPU 不可用" }
        return cpu.perCore.isEmpty ? "CPU 总占用" : "共 \(cpu.perCore.count) 逻辑核"
    }

    // MARK: 内存行

    /// 内存行：主值 used/total 可读化 + 副标题带压力档
    public static func memoryTexts(_ memory: MemoryUsage?) -> (value: String, subtitle: String) {
        guard let memory, memory.totalBytes > 0 else { return ("—", "内存不可用") }
        let value = "\(byteText(Double(memory.usedBytes)))/\(byteText(Double(memory.totalBytes)))"
        let tier = MemoryPressureTier.tier(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes)
        return (value, "内存 · \(tier?.displayName ?? "")")
    }

    // MARK: 网速行

    /// 网速行："↓ 下载 · ↑ 上传"（↓ in / ↑ out 与系统活动监视器方向约定一致）
    public static func netTexts(_ net: NetRates?) -> (value: String, subtitle: String) {
        guard let net else { return ("—", "网速不可用") }
        let value = "↓ \(rateText(net.bytesInPerSec)) · ↑ \(rateText(net.bytesOutPerSec))"
        return (value, "网速")
    }

    // MARK: GPU 行（T-203 回退链：activePercent 优先 → powerMilliwatts → 双 nil 隐藏）

    /// GPU 行三段映射：value 为 nil 时整行隐藏（无读数不占行高、不显示假 0%）。
    /// activePercent 有值时功率降为副标题；只有功率时按"~X mW 活跃度"口径展示
    /// （功率不是占用率，文案必须带"活跃度"避免误读成百分比）
    public static func gpuTexts(_ gpu: GpuUsage?) -> (value: String?, subtitle: String) {
        guard let gpu else { return (nil, "") }
        if let percent = gpu.activePercent {
            let powerText = gpu.powerMilliwatts.map { "~\(Int($0.rounded())) mW" }
            return ("\(Int(percent.rounded()))%", powerText ?? "GPU 活跃度")
        }
        if let milliwatts = gpu.powerMilliwatts {
            return ("~\(Int(milliwatts.rounded())) mW 活跃度", "以功率估活跃度")
        }
        return (nil, "")
    }

    // MARK: 字节可读化

    /// 1024 进制（与活动监视器一致）；<10 带一位小数、≥10 取整、字节档恒取整
    public static func byteText(_ bytes: Double) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 || value >= 10 {
            return "\(Int(value.rounded())) \(units[index])"
        }
        return String(format: "%.1f %@", value, units[index])
    }

    public static func rateText(_ bytesPerSec: Double) -> String {
        byteText(bytesPerSec) + "/s"
    }
}
