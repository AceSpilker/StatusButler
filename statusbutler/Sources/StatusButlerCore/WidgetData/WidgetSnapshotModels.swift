import Foundation

// T-054a 小组件数据半场（A6·4）：主 App ↔ WidgetKit 扩展的跨进程数据契约。
// 小组件由独立扩展进程渲染（A6·1），读不到主 App 内存——一切可展示数据以本快照为唯一载体。
// 这里钉死的是**文件格式契约**：主 App 写、扩展读，两端可能来自不同时间的构建，
// 因此编码形态必须显式手写（编译器为 enum 关联值合成的 Codable 形态属实现细节，随 Swift 版本演化过），不能靠合成。

/// 小组件快照：一个 JSON 文件装下全部组件所需的最低数据集（WG-01~04 的并集，扩展内存上限低，不留历史缓冲——A6·6）。
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// 当前模式版本；字段增删/形态变化必须 +1，读取侧据此做迁移或拒绝
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var generatedAt: Date
    /// 三合一状态（WG-01）；nil = 主 App 尚未产出过该域
    public var battery: BatteryState?
    public var link: NetworkLink?
    public var volume: VolumeState?
    /// 全部传感器中的最高温（WG-02；复用 ThermalMonitor 的口径）
    public var maxCelsius: Double?
    /// 风扇平均转速（WG-03）
    public var fanAverageRPM: Int?
    /// 网速（WG-04）。注意与 Monitoring/NetRateMonitor 的顶层 NetRates 是两个类型：
    /// 那个面向进程内采样（字段名跟监控器口径），这个是跨进程文件契约（键名钉死 "in"/"out"）
    public var netBytesPerSec: NetRates?

    /// 属性名用 backtick 避开关键字；成员访问按 SE-0071 可直接写 `rates.in`
    public struct NetRates: Codable, Sendable, Equatable {
        public var `in`: Double
        public var `out`: Double

        public init(`in`: Double, `out`: Double) {
            self.in = `in`
            self.out = `out`
        }
    }

    public init(
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
        generatedAt: Date,
        battery: BatteryState? = nil,
        link: NetworkLink? = nil,
        volume: VolumeState? = nil,
        maxCelsius: Double? = nil,
        fanAverageRPM: Int? = nil,
        netBytesPerSec: NetRates? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.battery = battery
        self.link = link
        self.volume = volume
        self.maxCelsius = maxCelsius
        self.fanAverageRPM = fanAverageRPM
        self.netBytesPerSec = netBytesPerSec
    }
}

// MARK: - 既有模型的 Codable 补齐
// Models/StatusSnapshot.swift 的 BatteryState/NetworkLink/VolumeState 只声明了 Equatable/Sendable；
// 本文件以扩展补上 Codable（同模块扩展合法，且不动既有文件）。
// 编码形态为"单键字典"：无关联值的 case 编 true，带 payload 的 case 编嵌套字典——
// 形态统一（解码端不必在字符串/字典两种 JSON 形态间分支），且是显式契约而非编译器合成。

extension BatteryState: Codable {
    private enum CodingKeys: String, CodingKey { case unavailable, battery }
    private enum PayloadKeys: String, CodingKey { case level, charging }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .unavailable) == true {
            self = .unavailable
            return
        }
        guard container.contains(.battery) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "未知 BatteryState 形态（契约见 WidgetSnapshotModels）"
            ))
        }
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .battery)
        self = .battery(
            level: try payload.decode(Int.self, forKey: .level),
            charging: try payload.decode(Bool.self, forKey: .charging)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable:
            try container.encode(true, forKey: .unavailable)
        case .battery(let level, let charging):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .battery)
            try payload.encode(level, forKey: .level)
            try payload.encode(charging, forKey: .charging)
        }
    }
}

extension NetworkLink: Codable {
    private enum CodingKeys: String, CodingKey { case offline, wifi, wired }
    private enum WifiKeys: String, CodingKey { case ssid, signalBars }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .offline) == true {
            self = .offline
            return
        }
        if try container.decodeIfPresent(Bool.self, forKey: .wired) == true {
            self = .wired
            return
        }
        guard container.contains(.wifi) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "未知 NetworkLink 形态（契约见 WidgetSnapshotModels）"
            ))
        }
        let payload = try container.nestedContainer(keyedBy: WifiKeys.self, forKey: .wifi)
        self = .wifi(
            ssid: try payload.decodeIfPresent(String.self, forKey: .ssid),
            signalBars: try payload.decode(Int.self, forKey: .signalBars)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offline:
            try container.encode(true, forKey: .offline)
        case .wired:
            try container.encode(true, forKey: .wired)
        case .wifi(let ssid, let signalBars):
            var payload = container.nestedContainer(keyedBy: WifiKeys.self, forKey: .wifi)
            try payload.encodeIfPresent(ssid, forKey: .ssid)
            try payload.encode(signalBars, forKey: .signalBars)
        }
    }
}

extension VolumeState: Codable {
    private enum CodingKeys: String, CodingKey { case level, isMuted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = VolumeState(
            level: try container.decode(Int.self, forKey: .level),
            isMuted: try container.decode(Bool.self, forKey: .isMuted)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encode(isMuted, forKey: .isMuted)
    }
}
