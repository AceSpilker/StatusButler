import CoreWLAN
import Foundation

// T-021 Wi-Fi 监控（CoreWLAN 真实现，替换 StaticWiFiMonitor 的拉取采样部分）
//
// 红线三（A2·S12 权限最小化）：macOS 读取 SSID 需要定位授权；无授权时 ssid()
// 返回 nil（不报错）。本层只消费授权结果、绝不主动申请——授权流归设置层
// （A2·S5：仅在用户开启 SSID 显示或打开链路详情时申请），监控层保持零权限依赖。
//
// 线程：CWInterface 的属性读取并发受限（非主线程/并发进入可能抛 ObjC 异常，
// 而 ObjC 异常无法被 Swift do-catch 捕获），CoreWLAN 的要求是主线程或加锁——
// 选择串行队列（= 锁）而非 DispatchQueue.main.sync：阻塞读取留在后台
// （AGENTS.md：阻塞 C API 后台执行），也避免未来有人在主线程上下文里同步等
// read() 时死锁。CWWiFiClient.shared() 官方线程安全但非 Sendable，不能作为
// Sendable struct 的存储属性缓存，故在队列内现取。

public struct WiFiMonitor: WiFiMonitoring {
    // 专用串行队列即锁：序列化全部 CoreWLAN 访问；struct 只存 Sendable 的队列
    private let queue = DispatchQueue(label: "statusbutler.monitor.wifi")

    public init() {}

    public func read() async -> NetworkLink {
        // sync 的闭包非逃逸、非 @Sendable，队列内接触 CWWiFiClient/CWInterface 不污染隔离
        queue.sync { Self.readLocked() }
    }

    private static func readLocked() -> NetworkLink {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            // 无 Wi-Fi 接口（无网卡机型）或硬件开关关闭：统一 offline，不虚构信号
            return .offline
        }
        // ssid() 无定位授权时返回 nil（不报错）——授权状态由设置层管理（见文件头）。
        // 电源开但 SSID 未知仍应显示"Wi-Fi 开"而非离线，ssid 降级为 nil
        let ssid = interface.ssid()
        // 未关联/读不到时 rssiValue() 可能回报 0；RSSI 物理上恒为负，
        // 非负读数按无信号处理，避免出现"未关联却满格"的假象
        let rawRSSI = interface.rssiValue()
        let rssi = rawRSSI >= 0 ? noSignalRSSI : rawRSSI
        return .wifi(ssid: ssid, signalBars: signalBars(rssi: rssi))
    }

    // 关联但 RSSI 不可读时的占位：远低于 -85 门限 → 0 格，与"未关联"视觉一致
    static let noSignalRSSI = -100

    /// RSSI(dBm) → 信号 4 级（A2·S5：Wi-Fi 信号弧 4 级）。门限被单测逐边界钉死。
    public static func signalBars(rssi: Int) -> Int {
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -75 { return 2 }
        if rssi >= -85 { return 1 }
        return 0
    }
}
