import Combine
import Foundation

// A14-γ 接线（A6·4/A6·5）——审计最痛点：主 App 从不写 widget-snapshot.json，
// 小组件永远空态。本文件补齐主 App 侧写入者：订阅三合一快照 + 温度 60s 粗读 +
// 性能总线网速 → 组装 WidgetSnapshot → shouldEmit 三元组节流 → writer 原子写 +
// Darwin 通知唤醒扩展。组件是旁路展示：任何写失败一律静默，不拖垮主 App。

/// 小组件快照写入协调器。
/// 数据来源三条腿（A6·4 图的"主 App 采样侧"）：
/// 1. store.$snapshot（电池/Wi-Fi/音量——本来为菜单栏图标常驻轮询，零额外成本）；
/// 2. ThermalMonitoring 60s 粗读（温度/风扇——旁路域，独立节拍不随快照走）；
/// 3. PerfBus 网速帧（PerfEngine 驱动，组件启用时集成方应 start 计数）。
@MainActor
public final class WidgetFeedCoordinator {
    /// 温度旁路读节拍（A6·1 能效：组件不需要秒级温度，60s 对 WG-02/03 足够）
    public static let thermalInterval: Duration = .seconds(60)

    private let store: SystemStatusStore
    private let thermal: any ThermalMonitoring
    private let bus: PerfBus
    private let writer: WidgetSnapshotWriter
    private let now: @Sendable () -> Date
    private let thermalReadInterval: Duration

    private var cancellables: Set<AnyCancellable> = []
    private var thermalTask: Task<Void, Never>?

    // 最近一帧旁路数据（快照域不缓存——订阅直达）
    private var maxCelsius: Double?
    private var fanAverageRPM: Int?
    private var netBytesPerSec: WidgetSnapshot.NetRates?

    // 节流状态（shouldEmit 的输入）
    private var lastEmitted: WidgetSnapshot?
    private var lastEmitAt: Date?

    public init(
        store: SystemStatusStore,
        thermal: any ThermalMonitoring,
        perf: PerfBus = PerfEngine.shared.bus,
        writer: WidgetSnapshotWriter,
        thermalReadInterval: Duration = WidgetFeedCoordinator.thermalInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.thermal = thermal
        self.bus = perf
        self.writer = writer
        self.thermalReadInterval = thermalReadInterval
        self.now = now
    }

    // MARK: - 生命周期（AppEnvironment 挂接点）

    public func start() {
        guard cancellables.isEmpty, thermalTask == nil else { return }
        // 腿 1：三合一快照（removeDuplicates：相等快照不重走组装，能效铁律）
        store.$snapshot
            .removeDuplicates()
            .sink { [weak self] _ in self?.emitFromCache() }
            .store(in: &cancellables)
        // 腿 3：网速帧（总线已去重；receive(main) 因 emit 路径在主隔离）
        bus.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self, let rates = sample?.net else { return }
                self.netBytesPerSec = WidgetSnapshot.NetRates(
                    in: rates.bytesInPerSec,
                    out: rates.bytesOutPerSec
                )
                self.emitFromCache()
            }
            .store(in: &cancellables)
        // 腿 2：温度/风扇 60s 粗读循环
        thermalTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readThermalOnce()
                guard let self else { return }
                try? await Task.sleep(
                    for: self.thermalReadInterval,
                    tolerance: self.thermalReadInterval / 5
                )
            }
        }
    }

    public func stop() {
        thermalTask?.cancel()
        thermalTask = nil
        cancellables.removeAll()
    }

    public var isRunning: Bool { thermalTask != nil }

    // MARK: - 组装与节流

    /// 温度旁路读一次（循环本体，也是测试的确定性入口）：读失败保留旧值（静默降级）。
    public func readThermalOnce() async {
        guard let reading = await thermal.read() else { return }
        maxCelsius = reading.maxCelsius
        fanAverageRPM = Self.fanAverageRPM(fans: reading.fans)
        emitFromCache()
    }

    /// 三条腿汇流点：用最近各域数据组装快照，过 shouldEmit 节流闸再落盘。
    func emitFromCache() {
        let next = WidgetSnapshot(
            generatedAt: now(),
            battery: store.snapshot.battery,
            link: store.snapshot.link,
            volume: store.snapshot.volume,
            maxCelsius: maxCelsius,
            fanAverageRPM: fanAverageRPM,
            netBytesPerSec: netBytesPerSec
        )
        let timestamp = now()
        guard WidgetSnapshotWriter.shouldEmit(
            previous: lastEmitted,
            next: next,
            lastEmitAt: lastEmitAt,
            now: timestamp
        ) else { return }
        do {
            try writer.write(next)
            lastEmitted = next
            lastEmitAt = timestamp
        } catch {
            // 磁盘满/目录不可建：静默降级（A6·4 写入纪律——组件旁路不该拖垮主 App）。
            // 不更新 lastEmit*/时间戳：下一帧三元组仍会重判，恢复后自动续写
        }
    }

    /// 风扇均值（WG-03）：读不到风扇（台式无风扇/解码失败）→ nil，不编造 0
    nonisolated static func fanAverageRPM(fans: [FanReading]) -> Int? {
        guard !fans.isEmpty else { return nil }
        let total = fans.reduce(0) { $0 + $1.currentRPM }
        return Int((Double(total) / Double(fans.count)).rounded())
    }
}
