import CoreWLAN
import Darwin
import Foundation
import IOKit

// MARK: - 附近网络扫描（A2·S5 下钻页一，A14-β）

/// 附近网络单行（值类型：CWNetwork 的 ObjC 引用绝不跨并发边界外泄）
public struct NearbyNetwork: Equatable, Sendable, Identifiable {
    /// 无定位授权时系统对 SSID 脱敏（nil）；降级显示走 displayName
    public let ssid: String?
    public let bssid: String?
    public let rssi: Int
    public let isSecure: Bool

    public init(ssid: String?, bssid: String?, rssi: Int, isSecure: Bool) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.isSecure = isSecure
    }

    /// BSSID 是设备级唯一键，扫描结果缺失时退回 SSID 复合键
    public var id: String { bssid ?? "ssid:\(ssid ?? "?")" }

    /// 展示名降级链：SSID → BSSID（无授权但有 BSSID 时）→ "隐藏网络"。
    /// 与系统行为一致：定位授权缺失时 CoreWLAN 可能同时脱敏 SSID/BSSID，如实占位
    public var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        if let bssid, !bssid.isEmpty { return bssid }
        return "隐藏网络"
    }

    /// 信号弧复用 Wi-Fi 监控的 4 级门限（门限被 WiFiMonitorTests 逐边界钉死，不另立标准）
    public var signalBars: Int { WiFiMonitor.signalBars(rssi: rssi) }
}

/// 列表排序（纯函数）：RSSI 降序（强信号在前），并列按展示名升序保证稳定输出
public enum NearbyNetworkOrder {
    public static func ordered(_ networks: [NearbyNetwork]) -> [NearbyNetwork] {
        networks.sorted { lhs, rhs in
            if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
            return lhs.displayName < rhs.displayName
        }
    }
}

/// 扫描服务协议（`-ing` 惯例，面板/测试注入假实现）
public protocol WiFiScanning: Sendable {
    /// 阻塞数秒的一次性扫描（按钮触发，绝不轮询——能效纪律）
    func scan() async -> [NearbyNetwork]
}

/// CoreWLAN 真实现。红线三：读取 SSID/BSSID 需定位授权，本层只消费授权结果、
/// 绝不主动申请（授权流归设置层，与 WiFiMonitor 同一纪律）；无授权时结果如实降级。
/// 扫描阻塞可达数秒，折进 detached 任务别占调用方协作线程
public struct SystemWiFiScanner: WiFiScanning {
    public init() {}

    public func scan() async -> [NearbyNetwork] {
        await Task.detached(priority: .userInitiated) { Self.scanOnce() }.value
    }

    static func scanOnce() -> [NearbyNetwork] {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            return []  // 无网卡/硬件开关关：空列表，不虚构网络
        }
        // includeHidden 的 10.13+ 变体（非 deprecated）：隐藏网络也进列表；
        // 新 SDK 把它重命名为 scanForNetworks(withSSID:)，旧 SDK 才有 scan(forNetworksWithSSID:)
        guard let networks = try? interface.scanForNetworks(withSSID: nil, includeHidden: true) else {
            return []
        }
        return networks.map { network in
            NearbyNetwork(
                ssid: network.ssid,
                bssid: network.bssid,
                rssi: network.rssiValue,
                // 开放网络才"支持无加密"；以此反推加密态，避免依赖随版本变动的 security 属性
                isSecure: !network.supportsSecurity(.none)
            )
        }
    }
}

// MARK: - 链路详情（A2·S5 下钻页二）

public enum InterfaceAddressFamily: String, Equatable, Sendable {
    case ipv4
    case ipv6
}

/// 单接口地址行（getifaddrs 折叠成值类型后才回流 UI）
public struct InterfaceAddressInfo: Equatable, Sendable {
    public let name: String      // "en0" / "utun3" / "lo0"
    public let address: String   // 数值串（NI_NUMERICHOST，不做 DNS 反查）
    public let family: InterfaceAddressFamily

    public init(name: String, address: String, family: InterfaceAddressFamily) {
        self.name = name
        self.address = address
        self.family = family
    }
}

/// 接口地址读取协议（注入）
public protocol InterfaceAddressReading: Sendable {
    func read() async -> [InterfaceAddressInfo]
}

/// getifaddrs 真实现（sysctl 底座的公开封装）。阻塞极短，仍按惯例折进 detached
public struct SystemInterfaceAddressReader: InterfaceAddressReading {
    public init() {}

    public func read() async -> [InterfaceAddressInfo] {
        await Task.detached(priority: .utility) { Self.readOnce() }.value
    }

    static func readOnce() -> [InterfaceAddressInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var result: [InterfaceAddressInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }

            guard let sockaddrPtr = entry.ifa_addr else { continue }
            let family = sockaddrPtr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            let length = family == UInt8(AF_INET)
                ? MemoryLayout<sockaddr_in>.size
                : MemoryLayout<sockaddr_in6>.size
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddrPtr, socklen_t(length), &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            result.append(InterfaceAddressInfo(
                name: String(cString: entry.ifa_name),
                address: String(cString: host),
                family: family == UInt8(AF_INET) ? .ipv4 : .ipv6
            ))
        }
        return result
    }
}

/// 链路详情展示映射（纯函数，单测喂假数据）
public enum LinkDetailsFormatting {
    public static func interfaceDisplayName(_ type: ConnectionInterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "以太网"
        case .cellular: return "蜂窝"
        case .loopback: return "回环"
        case .other: return "其他（隧道/VPN）"
        }
    }

    /// 接口汇总行：多接口并列（Wi-Fi + utun 隧道并存是常态）
    public static func interfaceSummary(details: ConnectionDetails) -> String {
        let names = details.interfaceTypes
            .sorted { $0.rawValue < $1.rawValue }
            .map { interfaceDisplayName($0) }
        return names.isEmpty ? "无活动接口" : names.joined(separator: " + ")
    }

    /// 状态徽标行（名，是否点亮）——VPN/受限/计费是 A2·S5 链路页的三项核心
    public static func flags(details: ConnectionDetails) -> [(label: String, isOn: Bool)] {
        [
            ("可达", details.isSatisfied),
            ("VPN 隧道", details.isVPN),
            ("低数据模式", details.isConstrained),
            ("计费链路", details.isExpensive),
        ]
    }

    /// 地址表 → 展示行：滤掉回环与链路本地 IPv6（fe80:: 每接口一串纯噪音），
    /// utun 保留——用户开 VPN 时靠它印证隧道确实在跑。排序：非回环在前、IPv4 前、接口名序
    public static func addressLines(_ addresses: [InterfaceAddressInfo]) -> [String] {
        addresses
            .filter { $0.name != "lo0" && !($0.family == .ipv6 && $0.address.hasPrefix("fe80:")) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                if lhs.family != rhs.family { return lhs.family == .ipv4 }
                return lhs.address < rhs.address
            }
            .map { "\($0.name) · \($0.address)" }
    }
}

/// ConnectionDetails 的面板注入协议（主线接 NetworkConnectionMonitor——同模块
/// retroactive conformance，与 ThermalMonitoring 包装 ThermalMonitor 同一姿势）
public protocol ConnectionDetailsProviding: Sendable {
    func read() async -> ConnectionDetails
}

extension NetworkConnectionMonitor: ConnectionDetailsProviding {}

// MARK: - 电池详情（A2·S4 下钻页三）

/// AppleSmartBattery 读数（IORegistry 键原样命名，缺测一律 nil，不虚构）
public struct BatteryDetails: Equatable, Sendable {
    public var cycleCount: Int?
    public var maxCapacity: Int?       // mAh 满充实际容量
    public var designCapacity: Int?    // mAh 设计容量
    public var voltageMillivolts: Int?
    public var amperageMilliamps: Int? // Apple 约定：负值 = 充电（电流流入）
    public var externalConnected: Bool
    public var isCharging: Bool

    public init(
        cycleCount: Int?,
        maxCapacity: Int?,
        designCapacity: Int?,
        voltageMillivolts: Int?,
        amperageMilliamps: Int?,
        externalConnected: Bool,
        isCharging: Bool
    ) {
        self.cycleCount = cycleCount
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.externalConnected = externalConnected
        self.isCharging = isCharging
    }
}

/// 电池详情读取协议（注入；台式机无 AppleSmartBattery 服务 → nil）
public protocol BatteryDetailsReading: Sendable {
    func read() async -> BatteryDetails?
}

/// IORegistry 真实现（公开 API，与系统电池面板同源；非 SMC 写域，只读不触红线二）
public struct IORegistryBatteryReader: BatteryDetailsReading {
    public init() {}

    public func read() async -> BatteryDetails? {
        await Task.detached(priority: .utility) { Self.readOnce() }.value
    }

    static func readOnce() -> BatteryDetails? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return BatteryDetailsMapping.details(from: dict)
    }
}

/// 纯映射：IORegistry 字典 → BatteryDetails / 健康度 / 功率（单测喂假 dict，不碰 IOKit）
public enum BatteryDetailsMapping {
    public static func details(from dict: [String: Any]) -> BatteryDetails {
        func intValue(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        func boolValue(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }
        return BatteryDetails(
            cycleCount: intValue("CycleCount"),
            maxCapacity: intValue("MaxCapacity"),
            designCapacity: intValue("DesignCapacity"),
            voltageMillivolts: intValue("Voltage"),
            amperageMilliamps: intValue("Amperage"),
            externalConnected: boolValue("ExternalConnected"),
            isCharging: boolValue("IsCharging")
        )
    }

    /// 健康度 = 满充实际/设计（A2·S4）：任一缺测/设计容量非正 → nil；结果钳制 0...100
    public static func healthPercent(maxCapacity: Int?, designCapacity: Int?) -> Int? {
        guard let maxCapacity, let designCapacity, designCapacity > 0, maxCapacity >= 0 else { return nil }
        let percent = Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
        return min(max(percent, 0), 100)
    }

    /// 瞬时功率：V(mV)×A(mA)=1e-6 W；符号跟随 Amperage（负 = 充电输入）。任一缺测 → nil
    public static func powerWatts(voltageMillivolts: Int?, amperageMilliamps: Int?) -> Double? {
        guard let voltageMillivolts, let amperageMilliamps, voltageMillivolts > 0 else { return nil }
        return Double(voltageMillivolts) * Double(amperageMilliamps) / 1_000_000
    }

    /// 电压展示（mV → V，两位小数）
    public static func voltageText(_ millivolts: Int?) -> String {
        guard let millivolts else { return "—" }
        return String(format: "%.2f V", Double(millivolts) / 1_000)
    }

    /// 功率展示："充电 x.x W"（负值翻正归充电）/ "放电 x.x W" / 缺测 "—"
    public static func powerText(voltageMillivolts: Int?, amperageMilliamps: Int?) -> String {
        guard let watts = powerWatts(voltageMillivolts: voltageMillivolts, amperageMilliamps: amperageMilliamps) else {
            return "—"
        }
        return watts < 0
            ? String(format: "充电 %.1f W", -watts)
            : String(format: "放电 %.1f W", watts)
    }
}

/// 电池健康度色档（80/60 双门限——Apple 官方"正常/服务"口径的细化）
public enum BatteryHealthTier: Equatable, Sendable {
    case normal
    case attention
    case replace

    public static func tier(forHealthPercent percent: Int?) -> BatteryHealthTier? {
        guard let percent else { return nil }
        if percent >= 80 { return .normal }
        if percent >= 60 { return .attention }
        return .replace
    }
}
