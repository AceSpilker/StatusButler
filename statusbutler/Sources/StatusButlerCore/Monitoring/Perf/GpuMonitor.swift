import Foundation

// T-203（A7·PF-30）：GPU 采样引擎——IOReport 回退链。
// 真机实测（arm64 macOS 26，2026-10，C 探针钉死）：
// 1. 本机不存在字面 "GPU Utilization"/"GPU Power" 组；实际可用通道为
//    GPU Stats/GPU Performance States（状态驻留，24Mticks，各态之和恰为流逝时间）
//    与 Energy Model/GPU|GPU Energy（mJ/nJ 能量计数器，双通道读数交叉一致）。
// 2. 服务绑定订阅（IOServiceGetMatchingService("AGXAccelerator") 后传入订阅）在本机段错误，
//    唯一稳定路线是系统级订阅（service 传 NULL）；本机 IOGPUDevice 名甚至匹配不到服务。
// 3. 通道枚举条目里 unit label 恒为空，单位只在采样/delta 条目里可见——
//    能力探测按组名判定、单位在解析帧时读取。
// 4. delta 条目的组名/单位/取值必须走专用 C 访问函数（IOReportChannelGet* 一族），
//    字典键直取不可靠。
// 以上即"通道名按真机探测为准"的落地依据；换机型重跑探测即自动适配或降级。

// MARK: - 模型（API 契约：并行面板端按此消费，字段与语义不可偏离）

/// GPU 使用帧（A7·PF-30 回退链的数据载体）：
/// activePercent = 硬件活跃驻留比（含显示合成驻留，与活动监视器口径略有差异，UI 需标注）；
/// powerMilliwatts = util 不可得时的活跃度代理（能量计数器差分 ÷ 流逝时间）。
/// 双 nil = 机型双通道皆不可得（headless/虚拟机），UI 据此走温度兜底文案——不是错误态。
public struct GpuUsage: Equatable, Sendable {
    public let activePercent: Double?
    public let powerMilliwatts: Double?

    public init(activePercent: Double? = nil, powerMilliwatts: Double? = nil) {
        self.activePercent = activePercent
        self.powerMilliwatts = powerMilliwatts
    }
}

// MARK: - 监控器协议（AGENTS：监控器全部协议化，测试注入假实现）

public protocol GpuMonitoring: Sendable {
    func read() async -> GpuUsage?
}

// MARK: - 能力矩阵与原始读数（纯数据，回退决策的输入）

/// 启动探测一次缓存的能力矩阵：决定 PF-30 回退链走哪条腿。
/// util 含两形态：状态驻留（GPU Stats/GPU Performance States，本机实测主路线）
/// 与标量累计（字面 "GPU Utilization" 组 ns，其他机型防御——本机不存在）。
public struct GpuChannelPlan: Equatable, Sendable {
    public let utilizationAvailable: Bool
    public let powerAvailable: Bool

    public init(utilizationAvailable: Bool, powerAvailable: Bool) {
        self.utilizationAvailable = utilizationAvailable
        self.powerAvailable = powerAvailable
    }

    public var hasAnyChannel: Bool { utilizationAvailable || powerAvailable }
}

/// 一帧未消毒的原始读数：越界值留给 resolve 判死刑（绝不显示假数据）。
public struct GpuRawReading: Equatable, Sendable {
    public let utilizationPercent: Double?
    /// 能量计数器差分（毫焦）；功耗 = mJ ÷ elapsedSeconds（mW = mJ/s）
    public let energyDeltaMillijoules: Double?
    public let elapsedSeconds: Double

    public init(
        utilizationPercent: Double?,
        energyDeltaMillijoules: Double?,
        elapsedSeconds: Double
    ) {
        self.utilizationPercent = utilizationPercent
        self.energyDeltaMillijoules = energyDeltaMillijoules
        self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - 监控器

/// GPU 一次性采样器：IOReport 系统级订阅两帧差分。
/// 采样纪律（A7·3）：订阅在首次 read 时惰性探测一次并进程内缓存（static 语义），
/// 之后仅被调用时采两帧各一次，无循环无定时器——"有人看才采样"。
public struct GpuMonitor: Sendable {
    /// 差分窗口：24Mticks 驻留计数分辨率下 150ms 足够累积；
    /// 与 CPU 的 100ms 窗口并行执行（async let），不叠加采样循环延迟
    public static let sampleWindow: Duration = .milliseconds(150)

    public init() {}

    public func read() async -> GpuUsage? {
        let session = GpuReportSession.shared
        // 探测即降级：无任何可用通道（headless/虚拟机）安全返回双 nil，不触碰 IOReport 采样
        guard session.plan.hasAnyChannel else {
            return GpuUsage(activePercent: nil, powerMilliwatts: nil)
        }
        guard let reading = await session.sampleDeltas(window: Self.sampleWindow) else { return nil }
        return Self.resolve(plan: session.plan, reading: reading)
    }

    // MARK: - 纯函数（单测入口）

    /// PF-30 回退决策：能力矩阵 + 原始读数 → 展示值。
    /// 通道不可得的维度强制 nil（读数再好也不越权展示）；NaN/负值/非正间隔判无效；
    /// 百分比 >100 钳制（驻留比四舍五入可轻微越界，非假数据）。
    public static func resolve(plan: GpuChannelPlan, reading: GpuRawReading) -> GpuUsage {
        var percent: Double?
        if plan.utilizationAvailable,
           let raw = reading.utilizationPercent, raw.isFinite, raw >= 0 {
            percent = min(raw, 100)
        }
        var milliwatts: Double?
        if plan.powerAvailable,
           let energy = reading.energyDeltaMillijoules, energy.isFinite, energy >= 0,
           reading.elapsedSeconds > 0 {
            milliwatts = energy / reading.elapsedSeconds
        }
        return GpuUsage(activePercent: percent, powerMilliwatts: milliwatts)
    }

    /// 状态驻留表 → 活跃%。非活跃态 = OFF/IDLE/DOWN（大小写不敏感，容老命名差异）；
    /// 多 GPU/多 die 时各通道 ticks 求和即聚合驻留。总和 0（窗口内无 tick）→ nil。
    public static func activePercent(states: [(name: String, ticks: Int64)]) -> Double? {
        var total = 0.0
        var active = 0.0
        for state in states {
            let value = Double(max(0, state.ticks))
            total += value
            let name = state.name.trimmingCharacters(in: .whitespaces).uppercased()
            if name != "OFF", name != "IDLE", name != "DOWN" {
                active += value
            }
        }
        guard total > 0 else { return nil }
        return min(active / total * 100, 100)
    }

    /// IOReport 能量单位 → 毫焦。未知单位返回 nil：宁可降级不换算错单位（不显示假数据）。
    public static func millijoules(value: Double, unitLabel: String) -> Double? {
        guard value.isFinite else { return nil }
        switch unitLabel.trimmingCharacters(in: .whitespaces) {
        case "J": return value * 1_000
        case "mJ": return value
        case "uJ", "µJ": return value / 1_000
        case "nJ": return value / 1_000_000
        default: return nil
        }
    }

    /// 标量利用率通道（ns 累计差分）→ 百分比。单位不是 ns 由调用侧把关，
    /// 此处只做数值消毒；tick 类单位无换算依据，不走此路。
    public static func scalarPercent(nanosecondsDelta: Double, elapsedSeconds: Double) -> Double? {
        guard nanosecondsDelta.isFinite, nanosecondsDelta >= 0,
              elapsedSeconds > 0 else { return nil }
        return min(nanosecondsDelta / (elapsedSeconds * 1e9) * 100, 100)
    }
}

extension GpuMonitor: GpuMonitoring {}

// MARK: - IOReport C 桥接（dlopen + dlsym；不改 Package.swift 就不直链 libIOReport）

// dlsym 取函数指针必须显式类型（无法从存储属性反推 @convention(c) 形状）。
// 原型按真机符号探测钉死：libIOReport 无公开头（tbd 在 CLT SDK）。
// CF 对象一律走 Unmanaged：Create/Copy 规则的返回 takeRetainedValue（ARC 接管，
// 绕开 Swift 禁用的 CFRelease），Get 规则的返回 takeUnretainedValue；入参 passUnretained。
private typealias IOReportCopyAllChannelsFn = @Sendable @convention(c) (
    _ channelTags: UnsafeMutableRawPointer?,
    _ allocator: UnsafeMutableRawPointer?
) -> Unmanaged<CFDictionary>?
private typealias IOReportCreateSubscriptionFn = @Sendable @convention(c) (
    // 服务参数真机实测必须 NULL（传 AGXAccelerator 端口段错误），签名保留以示原意
    _ service: UnsafeMutableRawPointer?,
    _ channels: UnsafeRawPointer?,
    _ subscribed: UnsafeMutablePointer<UnsafeRawPointer?>?,
    _ tolerance: UInt64,
    _ subService: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias IOReportCreateSamplesFn = @Sendable @convention(c) (
    _ subscription: UnsafeMutableRawPointer?,
    _ channels: UnsafeRawPointer?,
    _ service: UnsafeMutableRawPointer?
) -> Unmanaged<CFDictionary>?
private typealias IOReportCreateSamplesDeltaFn = @Sendable @convention(c) (
    _ previous: UnsafeRawPointer?,
    _ current: UnsafeRawPointer?,
    _ configuration: UnsafeMutableRawPointer?
) -> Unmanaged<CFDictionary>?
// delta 条目字段专用入口（字典键直取不可靠，真机实测）
private typealias IOReportChannelTextFn = @Sendable @convention(c) (_ channel: UnsafeRawPointer?) -> Unmanaged<CFString>?
private typealias IOReportSimpleIntegerFn = @Sendable @convention(c) (_ sample: UnsafeRawPointer?, _ index: Int32) -> Int64
private typealias IOReportStateCountFn = @Sendable @convention(c) (_ sample: UnsafeRawPointer?) -> Int32
private typealias IOReportStateNameFn = @Sendable @convention(c) (_ sample: UnsafeRawPointer?, _ index: Int32) -> Unmanaged<CFString>?
private typealias IOReportStateResidencyFn = @Sendable @convention(c) (_ sample: UnsafeRawPointer?, _ index: Int32) -> Int64

private enum IOReportBridge {
    struct API: Sendable {
        let copyAllChannels: IOReportCopyAllChannelsFn
        let createSubscription: IOReportCreateSubscriptionFn
        let createSamples: IOReportCreateSamplesFn
        let createSamplesDelta: IOReportCreateSamplesDeltaFn
        let channelGetGroup: IOReportChannelTextFn
        let channelGetSubGroup: IOReportChannelTextFn
        let channelGetChannelName: IOReportChannelTextFn
        let channelGetUnitLabel: IOReportChannelTextFn
        let simpleGetIntegerValue: IOReportSimpleIntegerFn
        let stateGetCount: IOReportStateCountFn
        let stateGetNameForIndex: IOReportStateNameFn
        let stateGetResidency: IOReportStateResidencyFn
    }

    /// dlopen/dlsym 失败或任一符号缺失 → nil → 探测得到空能力矩阵 → 双 nil 安全返回，绝不崩。
    /// 句柄为初始化局部量且有意不 dlclose：函数指针随进程生命周期有效（缓存即不拆）。
    static let api: API? = {
        guard let handle = dlopen("libIOReport.dylib", RTLD_LAZY)
            ?? dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copyAllChannels = symbol("IOReportCopyAllChannels", IOReportCopyAllChannelsFn.self),
              let createSubscription = symbol("IOReportCreateSubscription", IOReportCreateSubscriptionFn.self),
              let createSamples = symbol("IOReportCreateSamples", IOReportCreateSamplesFn.self),
              let createSamplesDelta = symbol("IOReportCreateSamplesDelta", IOReportCreateSamplesDeltaFn.self),
              let channelGetGroup = symbol("IOReportChannelGetGroup", IOReportChannelTextFn.self),
              let channelGetSubGroup = symbol("IOReportChannelGetSubGroup", IOReportChannelTextFn.self),
              let channelGetChannelName = symbol("IOReportChannelGetChannelName", IOReportChannelTextFn.self),
              let channelGetUnitLabel = symbol("IOReportChannelGetUnitLabel", IOReportChannelTextFn.self),
              let simpleGetIntegerValue = symbol("IOReportSimpleGetIntegerValue", IOReportSimpleIntegerFn.self),
              let stateGetCount = symbol("IOReportStateGetCount", IOReportStateCountFn.self),
              let stateGetNameForIndex = symbol("IOReportStateGetNameForIndex", IOReportStateNameFn.self),
              let stateGetResidency = symbol("IOReportStateGetResidency", IOReportStateResidencyFn.self)
        else { return nil }
        return API(
            copyAllChannels: copyAllChannels,
            createSubscription: createSubscription,
            createSamples: createSamples,
            createSamplesDelta: createSamplesDelta,
            channelGetGroup: channelGetGroup,
            channelGetSubGroup: channelGetSubGroup,
            channelGetChannelName: channelGetChannelName,
            channelGetUnitLabel: channelGetUnitLabel,
            simpleGetIntegerValue: simpleGetIntegerValue,
            stateGetCount: stateGetCount,
            stateGetNameForIndex: stateGetNameForIndex,
            stateGetResidency: stateGetResidency
        )
    }()
}

// MARK: - 订阅会话（探测一次缓存；actor 把 CF 私货关进隔离域）

/// GPU 通道订阅会话：进程内 static 缓存（"启动探测一次反复用"）。
/// CF 对象（通道字典等）以 ARC 托管形态存于 actor 属性——引用即保活；
/// 订阅引用（C 侧对象）按进程生命周期持有、有意不释放（缓存即不拆，AGENTS teardown 另论）。
private actor GpuReportSession {
    static let shared = GpuReportSession()

    /// 能力矩阵：不可变 Sendable 存储，actor 外同步读无竞争
    nonisolated let plan: GpuChannelPlan

    private let api: IOReportBridge.API?
    private let subscription: UnsafeMutableRawPointer?
    /// 通道字典与订阅回执必须以 ARC 值保活（裸指针不保命）
    private let channels: CFMutableDictionary?
    private let subscribed: CFMutableDictionary?

    private init() {
        guard let api = IOReportBridge.api else {
            self.api = nil
            self.plan = GpuChannelPlan(utilizationAvailable: false, powerAvailable: false)
            self.subscription = nil
            self.channels = nil
            self.subscribed = nil
            return
        }
        let probed = Self.probeAndSubscribe(api: api)
        self.api = api
        self.plan = probed.plan
        self.subscription = probed.subscription
        self.channels = probed.channels
        self.subscribed = probed.subscribed
    }

    /// 两帧差分采样：窗口内驻留比 + 能量差分。任一环节失败整帧 nil（read 端按域失败处理）。
    func sampleDeltas(window: Duration) async -> GpuRawReading? {
        guard let api, let subscription, let channels else { return nil }
        let channelsRef = Unmanaged.passUnretained(channels).toOpaque()
        guard let first = api.createSamples(subscription, channelsRef, nil)?.takeRetainedValue()
        else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        // 真实流逝时间做功耗分母：sleep 被取消/调度延迟时 mW 仍正确（与 NetRateMonitor 同理）
        try? await Task.sleep(for: window, tolerance: window / 5)
        let elapsed = Self.seconds(from: clock.now - start)
        guard let second = api.createSamples(subscription, channelsRef, nil)?.takeRetainedValue()
        else { return nil }
        guard let delta = api.createSamplesDelta(
            Unmanaged.passUnretained(first).toOpaque(),
            Unmanaged.passUnretained(second).toOpaque(),
            nil
        )?.takeRetainedValue() else { return nil }
        return Self.parse(api: api, delta: delta, elapsedSeconds: elapsed)
    }

    // MARK: - 探测与解析（nonisolated 静态：阻塞 C 调用收敛于此）

    /// 通道探测 + 系统级订阅。枚举条目 unit 恒空（真机实测），能力按组名判定；
    /// 无匹配通道即空矩阵不建订阅——headless/虚拟机的自然落点。
    nonisolated private static func probeAndSubscribe(api: IOReportBridge.API) -> (
        plan: GpuChannelPlan,
        subscription: UnsafeMutableRawPointer?,
        channels: CFMutableDictionary?,
        subscribed: CFMutableDictionary?
    ) {
        let empty: (GpuChannelPlan, UnsafeMutableRawPointer?, CFMutableDictionary?, CFMutableDictionary?) = (
            GpuChannelPlan(utilizationAvailable: false, powerAvailable: false), nil, nil, nil
        )
        guard let all = api.copyAllChannels(nil, nil)?.takeRetainedValue() else { return empty }
        guard let items = channelsArray(of: all) else { return empty }

        var wantsResidency = false
        var wantsScalar = false
        var wantsEnergy = false
        var callbacks = kCFTypeArrayCallBacks
        guard let selected = CFArrayCreateMutable(nil, 0, &callbacks) else { return empty }

        let count = CFArrayGetCount(items)
        for index in 0..<count {
            let item = item(at: index, of: items)
            let group = text(api.channelGetGroup(item))
            let subGroup = text(api.channelGetSubGroup(item))
            let channel = text(api.channelGetChannelName(item))
            // 驻留型 util：GPU Stats/GPU Performance States（真机实测主路线）
            if group == "GPU Stats", subGroup == "GPU Performance States" {
                wantsResidency = true
                CFArrayAppendValue(selected, item)
                continue
            }
            // 标量型 util：字面 "GPU Utilization" 组（其他机型防御，本机不存在）
            if group == "GPU Utilization" {
                wantsScalar = true
                CFArrayAppendValue(selected, item)
                continue
            }
            // 功耗代理：Energy Model 能量计数器（GPU mJ 与 GPU Energy nJ 双收，
            // 解析按优先级取一——两通道读数实测交叉一致）
            if group == "Energy Model", channel == "GPU" || channel == "GPU Energy" {
                wantsEnergy = true
                CFArrayAppendValue(selected, item)
            }
        }
        guard CFArrayGetCount(selected) > 0 else { return empty }

        guard let mutableChannels = CFDictionaryCreateMutableCopy(nil, 0, all) else { return empty }
        let channelsKey = Unmanaged<CFString>.passUnretained("IOReportChannels" as CFString).toOpaque()
        CFDictionarySetValue(mutableChannels, channelsKey, Unmanaged.passUnretained(selected).toOpaque())

        // 订阅回执的 CF 对象经 C 侧落到 UnsafeRawPointer?——ARC 保活走 fromOpaque
        var subscribedOpaque: UnsafeRawPointer?
        guard let subscription = api.createSubscription(
            nil, Unmanaged.passUnretained(mutableChannels).toOpaque(), &subscribedOpaque, 0, nil
        ) else { return empty }
        let subscribed = subscribedOpaque.map {
            Unmanaged<CFMutableDictionary>.fromOpaque($0).takeUnretainedValue()
        }
        return (
            GpuChannelPlan(
                utilizationAvailable: wantsResidency || wantsScalar,
                powerAvailable: wantsEnergy
            ),
            subscription,
            mutableChannels,
            subscribed
        )
    }

    /// delta 帧解析 → 原始读数。驻留通道优先于标量；能量取 GPU(mJ) 优先、GPU Energy(nJ) 兜底。
    nonisolated private static func parse(
        api: IOReportBridge.API,
        delta: CFDictionary,
        elapsedSeconds: Double
    ) -> GpuRawReading? {
        guard let items = channelsArray(of: delta) else { return nil }

        var residencyStates: [(name: String, ticks: Int64)] = []
        var scalarNanoseconds: Double?
        var energyPrimary: Double?
        var energyFallback: Double?

        let count = CFArrayGetCount(items)
        for index in 0..<count {
            let item = item(at: index, of: items)
            let group = text(api.channelGetGroup(item))
            let subGroup = text(api.channelGetSubGroup(item))
            let channel = text(api.channelGetChannelName(item))
            let unit = text(api.channelGetUnitLabel(item))

            if group == "GPU Stats", subGroup == "GPU Performance States" {
                let states = Int(api.stateGetCount(item))
                for stateIndex in 0..<states {
                    if let name = text(api.stateGetNameForIndex(item, Int32(stateIndex))) {
                        residencyStates.append(
                            (name: name, ticks: api.stateGetResidency(item, Int32(stateIndex)))
                        )
                    }
                }
                continue
            }
            if group == "GPU Utilization", unit == "ns" {
                scalarNanoseconds = Double(api.simpleGetIntegerValue(item, 0))
                continue
            }
            if group == "Energy Model", channel == "GPU" {
                energyPrimary = GpuMonitor.millijoules(
                    value: Double(api.simpleGetIntegerValue(item, 0)),
                    unitLabel: unit ?? ""
                )
                continue
            }
            if group == "Energy Model", channel == "GPU Energy", energyPrimary == nil {
                energyFallback = GpuMonitor.millijoules(
                    value: Double(api.simpleGetIntegerValue(item, 0)),
                    unitLabel: unit ?? ""
                )
            }
        }

        let utilization = residencyStates.isEmpty
            ? scalarNanoseconds.flatMap {
                GpuMonitor.scalarPercent(nanosecondsDelta: $0, elapsedSeconds: elapsedSeconds)
            }
            : GpuMonitor.activePercent(states: residencyStates)
        return GpuRawReading(
            utilizationPercent: utilization,
            energyDeltaMillijoules: energyPrimary ?? energyFallback,
            elapsedSeconds: elapsedSeconds
        )
    }

    // MARK: - CF 结构小工具（顶层 "IOReportChannels" 数组的固定取法）

    nonisolated private static func channelsArray(of dictionary: CFDictionary) -> CFArray? {
        let key = Unmanaged<CFString>.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let value = CFDictionaryGetValue(dictionary, key) else { return nil }
        // 本 SDK 的 CFDictionaryGetValue 返回 UnsafeRawPointer!（Get 规则）：容器保活下零转移取值
        return Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue()
    }

    /// 数组元素（Get 规则）：容器在作用域内保活，takeUnretainedValue 零转移
    nonisolated private static func item(at index: CFIndex, of array: CFArray) -> UnsafeRawPointer? {
        guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
        return pointer
    }

    nonisolated private static func text(_ string: Unmanaged<CFString>?) -> String? {
        string.map { $0.takeUnretainedValue() as String }
    }

    nonisolated static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
