import Combine

// 状态仓库：聚合监控器为单一快照。事件驱动通道随 T-020+ 接入，
// 当前为轮询骨架（间隔 + 宽容 = 间隔/5，不要求 CPU 精确唤醒 —— B1 能效纪律）
@MainActor
public final class SystemStatusStore: ObservableObject {
    @Published public private(set) var snapshot: StatusSnapshot = .empty

    private let battery: any BatteryMonitoring
    private let wifi: any WiFiMonitoring
    private let volume: any VolumeMonitoring
    private let refreshInterval: Duration
    private var refreshTask: Task<Void, Never>?

    public init(
        battery: any BatteryMonitoring,
        wifi: any WiFiMonitoring,
        volume: any VolumeMonitoring,
        refreshInterval: Duration = .seconds(15)
    ) {
        self.battery = battery
        self.wifi = wifi
        self.volume = volume
        self.refreshInterval = refreshInterval
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                try? await Task.sleep(
                    for: self.refreshInterval,
                    tolerance: self.refreshInterval / 5
                )
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 单次拉取（内部供轮询，public 供测试与手动刷新）
    public func refresh() async {
        async let battery = battery.read()
        async let link = wifi.read()
        async let volume = volume.read()
        snapshot = await StatusSnapshot(
            battery: battery,
            link: link,
            volume: volume
        )
    }
}
