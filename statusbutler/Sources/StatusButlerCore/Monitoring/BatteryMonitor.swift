import Foundation
import IOKit.ps

// T-020: IOKit 电源描述（公开 API，与系统菜单栏电池同源）→ BatteryState。
// IOPS 读取是毫秒级同步快照，放 nonisolated 静态函数执行，不占用任何 actor
// （B1 能效：Store 轮询间隔 15s，读取开销可忽略）
public struct BatteryMonitor: BatteryMonitoring {
    public init() {}

    public func read() async -> BatteryState {
        // 容错：IOKit 任一步失败（无电池 / 取不到描述 / 类型异常）一律归 .unavailable，
        // 台式 Mac 只有 "AC Power" 源、无容量键，同样由纯函数落 .unavailable
        Self.livePowerSourceDescription().map { Self.state(from: $0) } ?? .unavailable
    }

    /// 直读系统电源源描述（nonisolated：纯同步 C API，不依赖共享可变状态）
    static func livePowerSourceDescription() -> [String: Any]? {
        guard let blobRaw = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobRaw.takeRetainedValue()
        guard let listRaw = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listRaw.takeRetainedValue() as [CFTypeRef]

        var firstDescription: [String: Any]?
        for id in list {
            // 描述字典归 blob 所有（caller 不持有），必须 takeUnretainedValue
            guard let descRaw = IOPSGetPowerSourceDescription(blob, id) else { continue }
            guard let dict = descRaw.takeUnretainedValue() as? [String: Any] else { continue }
            if dict[kIOPSTypeKey] as? String == kIOPSBatteryPowerValue { return dict }
            if firstDescription == nil { firstDescription = dict }
        }
        return firstDescription
    }

    /// 纯映射：IOPS 描述字典 → BatteryState（单测喂假字典，不碰 IOKit）。
    /// 容量键按百分比解释（IOPS 默认 Max Capacity = 100）；越界钳制到 0...100，
    /// 防止渲染层拿到非法百分比；缺容量键或电池不在位 = .unavailable
    public static func state(from description: [String: Any]) -> BatteryState {
        if let isPresent = description[kIOPSIsPresentKey] as? Bool, !isPresent {
            return .unavailable
        }
        guard let capacity = description[kIOPSCurrentCapacityKey] as? Int else {
            return .unavailable
        }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        return .battery(level: min(max(capacity, 0), 100), charging: charging)
    }
}
