import Foundation

// E1 信号槽 v1（A8·SL）：槽位源协议 + 注册表 + 首批"被动源"（由快照/时钟即时推导）。
// 主动采样源（网速/CPU/温度等）随 T-025+/T-027+ 接入，扩展协议加 start/stop。
public struct SlotScene: Equatable, Sendable {
    public var symbol: String?
    public var valueText: String?
    public var level: Int?        // 0...4 分级点
    public var isWarning: Bool    // true = 红色警示

    public init(symbol: String? = nil, valueText: String? = nil, level: Int? = nil, isWarning: Bool = false) {
        self.symbol = symbol
        self.valueText = valueText
        self.level = level
        self.isWarning = isWarning
    }
}

public protocol SlotSource: Sendable {
    var id: String { get }
    /// 返回 nil = 该源当前无数据（注册表中保留占位）
    func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene?
}

// MARK: - 首批内置源

public struct VolumeSlot: SlotSource {
    public let id = "volume"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        let dots = snapshot.volume.isMuted
            ? 0
            : Int((Double(snapshot.volume.level) / 100 * 4).rounded())
        return SlotScene(
            symbol: snapshot.volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            valueText: nil,
            level: dots,
            isWarning: snapshot.volume.isMuted
        )
    }
}

public struct ClockSlot: SlotSource {
    public let id = "clock"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return SlotScene(symbol: nil, valueText: formatter.string(from: now), level: nil)
    }
}

public struct BatteryPercentSlot: SlotSource {
    public let id = "batteryPercent"
    public init() {}
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard case .battery(let level, _) = snapshot.battery else { return nil }
        return SlotScene(
            symbol: "battery.100",
            valueText: "\(level)%",
            level: Int((Double(level) / 100 * 4).rounded()),
            isWarning: level <= 20
        )
    }
}

public struct DiskFreeSlot: SlotSource {
    public let id = "diskFree"
    private let available: @Sendable () -> Int64?
    public init(available: @escaping @Sendable () -> Int64? = { nil }) {
        self.available = available
    }
    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        guard let bytes = available() else { return nil }
        let gb = Double(bytes) / 1e9
        return SlotScene(symbol: "internaldrive", valueText: String(format: "%.0fG", gb), level: nil)
    }
}

// MARK: - 注册表与组合器

public enum SlotRegistry {
    /// 首批可用源；后续随监控域接入扩充（A8·SL-02 全表）
    public static let builtin: [String: any SlotSource] = {
        var map: [String: any SlotSource] = [
            VolumeSlot().id: VolumeSlot(),
            ClockSlot().id: ClockSlot(),
            BatteryPercentSlot().id: BatteryPercentSlot(),
            DiskFreeSlot().id: DiskFreeSlot(),
        ]
        // 待数据源的占位（T-025/T-027/T-040+ 接入后替换实现）
        // T-041 已接入真实源；其余待数据
        for pending in ["netSpeed", "cpuUsage", "memoryPressure", "temperature", "weather"] {
            map[pending] = PendingSlot(id: pending)
        }
        map["calendarCountdown"] = CalendarSlot(provider: LiveEventStore())
        return map
    }()

    public static func source(id: String) -> (any SlotSource)? {
        builtin[id]
    }
}

struct PendingSlot: SlotSource {
    let id: String
    func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? { nil }
}

/// 底部槽位组合器：按设置取活动源，产出场景
public struct SlotComposer: Sendable {
    public let selectedID: String
    public init(selectedID: String) { self.selectedID = selectedID }

    public func footer(snapshot: StatusSnapshot, now: Date = Date()) -> SlotScene? {
        SlotRegistry.source(id: selectedID)?.scene(snapshot: snapshot, now: now)
    }
}
