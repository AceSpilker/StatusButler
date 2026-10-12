// 快照：能画进图标的状态进这里；快照相等 = 图标不变（渲染缓存 key）
public enum BatteryState: Equatable, Sendable {
    case unavailable
    case battery(level: Int, charging: Bool)
}

public enum NetworkLink: Equatable, Sendable {
    case offline
    case wifi(ssid: String?, signalBars: Int)
    case wired
}

public struct VolumeState: Equatable, Sendable {
    public var level: Int
    public var isMuted: Bool

    public init(level: Int, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }
}

public struct StatusSnapshot: Equatable, Sendable {
    public var battery: BatteryState
    public var link: NetworkLink
    public var volume: VolumeState

    public init(
        battery: BatteryState,
        link: NetworkLink,
        volume: VolumeState
    ) {
        self.battery = battery
        self.link = link
        self.volume = volume
    }

    public static let empty = StatusSnapshot(
        battery: .unavailable,
        link: .offline,
        volume: VolumeState(level: 0, isMuted: false)
    )
}
