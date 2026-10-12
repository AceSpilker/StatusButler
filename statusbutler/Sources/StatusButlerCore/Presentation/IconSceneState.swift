// 展示映射层（纯函数）：快照 → 图标场景。状态不变不重绘的根基
public struct IconSceneState: Equatable, Sendable {
    /// 顶部：电池 0...100；nil = 无电池设备
    public var batteryLevel: Int?
    public var isCharging: Bool

    /// 中部：信号格 0...4；offline 时为 0
    public var signalBars: Int

    /// 底部：音量点 0...4；静音强制 0
    public var volumeDots: Int
    public var isMuted: Bool

    public init(
        batteryLevel: Int?,
        isCharging: Bool,
        signalBars: Int,
        volumeDots: Int,
        isMuted: Bool
    ) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.signalBars = min(max(signalBars, 0), 4)
        self.volumeDots = min(max(volumeDots, 0), 4)
        self.isMuted = isMuted
    }

    public static let empty = IconSceneState(
        batteryLevel: nil, isCharging: false,
        signalBars: 0, volumeDots: 0, isMuted: false
    )

    /// 快照 → 场景（A2·S1 初版：百分比/充电/信号/音量四要素）
    public static func from(_ snapshot: StatusSnapshot) -> IconSceneState {
        let battery: Int?
        var charging = false
        if case .battery(let level, let isCharging) = snapshot.battery {
            battery = level
            charging = isCharging
        } else {
            battery = nil
        }

        let bars: Int
        switch snapshot.link {
        case .wifi(_, let signalBars): bars = signalBars
        case .wired: bars = 4          // 有线视为满格（E1 槽位化后可配）
        case .offline: bars = 0
        }

        let dots = snapshot.volume.isMuted
            ? 0
            : Int((Double(snapshot.volume.level) / 100.0 * 4.0).rounded())

        return IconSceneState(
            batteryLevel: battery,
            isCharging: charging,
            signalBars: bars,
            volumeDots: dots,
            isMuted: snapshot.volume.isMuted
        )
    }
}
