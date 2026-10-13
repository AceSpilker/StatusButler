import Combine
import Foundation

// A14-γ 接线（A7·PF）：性能采样引擎——三采样器（CPU/内存/网速）的常驻编排层。
// 之前三 monitor 只有一次性的 read()（纯函数全绿但无人调用、netSpeed/cpuUsage 槽位占位），
// 本文件补"采样循环"半场，纪律照旧：**有人看才采样**——引用计数多消费者闸门，
// 弹层可见/槽位选中/小组件启用各自 start(reason)/stop(reason)，计数归零即撤循环。

// MARK: - 监控器协议化（AGENTS：监控器全部协议化，测试注入假实现）

public protocol CpuMonitoring: Sendable {
    func read() async -> CpuUsage?
}

public protocol MemoryMonitoring: Sendable {
    func read() async -> MemoryUsage?
}

public protocol NetRateMonitoring: Sendable {
    func read() async -> NetRates?
}

// 既有 struct 原样收编（同模块 retroactive 包装，不动其文件——沿用 ThermalMonitoring 惯例）
extension CpuMonitor: CpuMonitoring {}
extension MemoryMonitor: MemoryMonitoring {}
extension NetRateMonitor: NetRateMonitoring {}

// MARK: - 采样帧

/// 一帧性能采样：各域并读的并集，任一域失败该域为 nil（其余照常发布）。
/// gpu 为 T-203 增补域：默认 nil 保持既有构造兼容（GPU 引擎缺席时帧不带 GPU）。
public struct PerfSample: Sendable {
    public let cpu: CpuUsage?
    public let memory: MemoryUsage?
    public let net: NetRates?
    public let gpu: GpuUsage?
    public let at: Date

    public init(
        cpu: CpuUsage?,
        memory: MemoryUsage?,
        net: NetRates?,
        gpu: GpuUsage? = nil,
        at: Date = Date()
    ) {
        self.cpu = cpu
        self.memory = memory
        self.net = net
        self.gpu = gpu
        self.at = at
    }
}

extension PerfSample: Equatable {
    /// 相等性刻意不含 `at`：去重语义是"数据变了没有"而非"时钟走了没有"——
    /// 下游 removeDuplicates 据此在系统静默期不产生第二帧（能效铁律：订阅去重）。
    public static func == (lhs: PerfSample, rhs: PerfSample) -> Bool {
        lhs.cpu == rhs.cpu && lhs.memory == rhs.memory && lhs.net == rhs.net && lhs.gpu == rhs.gpu
    }
}

// MARK: - 发布总线

/// 性能帧总线：CurrentValueSubject 脊柱，引擎写、槽位同步读、订阅者异步收。
/// @unchecked Sendable 论证：唯一存储是 CurrentValueSubject（Combine 主题官方线程安全，
/// Output/Failure 均 Sendable），无其他可变状态——send/value/订阅可从任意线程。
/// 槽位源（SlotSource.scene 是同步协议）从这里免隔离读最近一帧。
public final class PerfBus: @unchecked Sendable {
    private let subject = CurrentValueSubject<PerfSample?, Never>(nil)

    public init() {}

    /// 最近一帧；nil = 采样从未成功（引擎未启动或首帧未到）
    public var sample: PerfSample? { subject.value }

    /// 订阅端：订阅即回放当前值（CurrentValueSubject 语义），经 removeDuplicates 去重
    public var publisher: some Publisher<PerfSample?, Never> { subject.removeDuplicates() }

    /// 引擎写入端（每采样节拍一次）
    public func send(_ sample: PerfSample?) { subject.send(sample) }
}

// MARK: - @MainActor 发布器

/// 快照发布器（Store/控制器 @MainActor 纪律）：总线 → ObservableObject 的 SwiftUI 适配层。
/// 弹层性能分区（A7·PF-09）后续直接 @ObservedObject 本类；槽位与引擎一律走总线，
/// 两端共享同一 bus 实例即同源同帧。
@MainActor
public final class PerfFeed: ObservableObject {
    @Published public private(set) var sample: PerfSample?

    /// 引擎与槽位共用的总线
    public let bus: PerfBus
    private var cancellables: Set<AnyCancellable> = []

    public init(bus: PerfBus = PerfBus()) {
        self.bus = bus
        sample = bus.sample
        // 总线 → @Published 镜像：subject.send 本身线程安全，但 @Published 的
        // willSet 通知须在主线程才对 SwiftUI 安全——receive(main) 钉死写侧
        bus.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.sample = value }
            .store(in: &cancellables)
    }

    /// 手动写入口（测试/手动刷新）
    public func apply(_ value: PerfSample?) { bus.send(value) }
}

// MARK: - 引擎

/// 引用计数采样引擎（actor：消费者集合与循环任务的互斥由 actor 保证）。
/// start/stop 以 reason 为键：弹层可见、槽位选中、组件启用等消费者各自计数，
/// 计数归零 cancel 循环——"有人看才采样"的多消费者扩展。
public actor PerfEngine {
    /// A7·3 弹层/组件观察态的采样节拍：1s 足够人类可感知又低于 mach tick 分辨率浪费
    public static let defaultInterval: Duration = .seconds(1)

    private let cpu: any CpuMonitoring
    private let memory: any MemoryMonitoring
    private let net: any NetRateMonitoring
    private let gpu: any GpuMonitoring
    private let interval: Duration

    /// 发布总线：非隔离 let（Sendable），槽位注册表可从渲染上下文直接读
    public let bus: PerfBus

    private var consumers: Set<String> = []
    private var loop: Task<Void, Never>?

    public init(
        cpu: any CpuMonitoring = CpuMonitor(),
        memory: any MemoryMonitoring = MemoryMonitor(),
        net: any NetRateMonitoring = NetRateMonitor(),
        gpu: any GpuMonitoring = GpuMonitor(),
        bus: PerfBus = PerfBus(),
        interval: Duration = PerfEngine.defaultInterval
    ) {
        self.cpu = cpu
        self.memory = memory
        self.net = net
        self.gpu = gpu
        self.bus = bus
        self.interval = interval
    }

    /// 组合根默认实例：槽位注册表绑它的总线；AppEnvironment 持同一实例做 start/stop。
    /// 构造零成本——不 start 就没有任何采样发生
    public static let shared = PerfEngine()

    /// 工厂（AppEnvironment 装配点，等价默认实例；显式命名便于集成清单检索）
    public static func live() -> PerfEngine { PerfEngine() }

    /// 采样中（测试与接线方可观测）
    public var isSampling: Bool { loop != nil }

    /// 当前消费者数（引用计数的观测面）
    public var consumerCount: Int { consumers.count }

    /// 消费者登记：计数 0→1 时起循环；重复 reason 幂等
    public func start(_ reason: String) {
        consumers.insert(reason)
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce()
                try? await Task.sleep(for: self.interval, tolerance: self.interval / 5)
            }
        }
    }

    /// 消费者注销：计数归零 cancel 循环。未知 reason 静默忽略（stop 永不误伤他人）
    public func stop(_ reason: String) {
        consumers.remove(reason)
        if consumers.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    /// 单帧采样：各域并读，任一失败不影响其余域（部分降级好过整帧丢弃）。
    /// GPU 域失败（含 headless 双 nil）静默随帧——150ms 差分窗口与 CPU 的 100ms 并行，不拖节拍。
    public func sampleOnce() async {
        async let cpuSample = cpu.read()
        async let memorySample = memory.read()
        async let netSample = net.read()
        async let gpuSample = gpu.read()
        let sample = await PerfSample(
            cpu: cpuSample, memory: memorySample, net: netSample, gpu: gpuSample
        )
        bus.send(sample)
    }
}
