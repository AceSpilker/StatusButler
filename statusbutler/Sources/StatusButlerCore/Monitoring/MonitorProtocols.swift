// 监控层协议：全部可注入假实现（T-003 测试依赖此抽象）
// 真实实现随 T-020+ 逐域接入；当前提供静态监控器让组合根可运行
public protocol BatteryMonitoring: Sendable {
    func read() async -> BatteryState
}

public protocol WiFiMonitoring: Sendable {
    func read() async -> NetworkLink
}

public protocol VolumeMonitoring: Sendable {
    func read() async -> VolumeState
}

public struct StaticBatteryMonitor: BatteryMonitoring {
    private let state: BatteryState
    public init(_ state: BatteryState) { self.state = state }
    public func read() async -> BatteryState { state }
}

public struct StaticWiFiMonitor: WiFiMonitoring {
    private let link: NetworkLink
    public init(_ link: NetworkLink) { self.link = link }
    public func read() async -> NetworkLink { link }
}

public struct StaticVolumeMonitor: VolumeMonitoring {
    private let state: VolumeState
    public init(_ state: VolumeState) { self.state = state }
    public func read() async -> VolumeState { state }
}
