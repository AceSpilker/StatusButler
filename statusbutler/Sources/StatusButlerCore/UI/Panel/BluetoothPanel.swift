import Foundation
import IOBluetooth
import IOKit

// MARK: - 蓝牙操作（A2·S7：设备行连接/断开，A14-β）

public protocol BluetoothOperating: Sendable {
    /// address 为 IOBluetooth addressString（与 BluetoothDeviceInfo.address 同源）。
    /// 返回 false = 系统拒绝/设备失联——如实回报，面板不伪装成功
    @discardableResult
    func setConnected(_ connected: Bool, address: String) async -> Bool
}

/// IOBluetooth 公开通道真实现（与系统蓝牙菜单同一落点）。ObjC 往返折进 detached 任务
public struct IOBluetoothOperator: BluetoothOperating {
    public init() {}

    public func setConnected(_ connected: Bool, address: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            // ObjC 类工厂 +deviceWithAddressString: 导入为便捷构造器
            guard let device = IOBluetoothDevice(addressString: address) else { return false }
            if connected {
                return device.openConnection() == kIOReturnSuccess
            }
            device.closeConnection()
            return true
        }.value
    }
}

// MARK: - HID 断开二次确认（纯状态机）

/// HID（键鼠/触控板/手柄）断开先"再点一次"（A2·S7）：断掉正在使用的输入设备代价高，
/// 误触必须可拦。纯值类型 + 时间注入，视图只消费 armedAddress 决定按钮文案
public struct HIDConfirmModel: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 3

    public private(set) var armedAddress: String?
    public private(set) var armedAt: Date?

    public init() {}

    public static func isHIDKind(_ kind: BluetoothDeviceKind) -> Bool {
        switch kind {
        case .keyboard, .mouse, .trackpad, .gamepad: return true
        case .headphone, .speaker, .wearable, .other: return false
        }
    }

    /// 断开点击流转：未武装 → 武装（false，UI 提示"再点一次"）；已武装同地址 → 确认执行（true）并清空；
    /// 武装过期 → 重新武装；点击了别的设备 → 换目标重新武装
    @discardableResult
    public mutating func tapDisconnect(address: String, now: Date, timeout: TimeInterval = defaultTimeout) -> Bool {
        expire(now: now, timeout: timeout)
        if armedAddress == address {
            armedAddress = nil
            armedAt = nil
            return true
        }
        armedAddress = address
        armedAt = now
        return false
    }

    /// 目标设备离场（清单刷新后失联）时失效武装，防止对已消失地址误执行
    public mutating func invalidate(address: String) {
        if armedAddress == address {
            armedAddress = nil
            armedAt = nil
        }
    }

    public mutating func reset() {
        armedAddress = nil
        armedAt = nil
    }

    public mutating func expire(now: Date, timeout: TimeInterval = defaultTimeout) {
        if let armedAt, now.timeIntervalSince(armedAt) >= timeout {
            self.armedAddress = nil
            self.armedAt = nil
        }
    }
}

// MARK: - 蓝牙电量两源合并接线（T-023b 引擎 → 面板，A14-β）

/// 面板"设备+电量"行数据源协议（注入；BatteryMerge.merge 是引擎半场，本协议是旁路接线）
public protocol BluetoothBatteryMerging: Sendable {
    func read() async -> [BluetoothDeviceWithBattery]
}

/// 真实现：IOBluetooth 设备清单 + pmset 配件电量表 → BatteryMerge 合并。
/// 两源并发各读一次（都是短查询），合并纯函数收口
public struct SystemBluetoothBatterySource: BluetoothBatteryMerging {
    private let devices: BluetoothMonitor
    private let accessory: AccessoryBatterySource

    public init(
        devices: BluetoothMonitor = BluetoothMonitor(),
        accessory: AccessoryBatterySource = AccessoryBatterySource()
    ) {
        self.devices = devices
        self.accessory = accessory
    }

    public func read() async -> [BluetoothDeviceWithBattery] {
        async let devices = devices.read()
        async let levels = accessory.read()
        return await BatteryMerge.merge(devices: devices, accessoryLevels: levels)
    }
}

// MARK: - 蓝牙展示映射（纯函数）

public enum BluetoothPanelDisplay {
    /// 设备种类 → SF Symbol（macOS 13 系统符号集内取名字，不按系统版本分支）
    public static func symbolName(for kind: BluetoothDeviceKind) -> String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"  // SF4 起 macOS 13 有此名
        case .trackpad: return "hand.tap"  // CoD 无法区分鼠标/触控板（见 BluetoothDeviceKind 注释），图标同级模糊是诚实选择
        case .gamepad: return "gamecontroller"
        case .headphone: return "headphones"
        case .speaker: return "hifispeaker.2.fill"
        case .wearable: return "applewatch"
        case .other: return "bluetooth"
        }
    }

    /// AirPods 三仓位展开行（A2·S6）：缺盒是常态（耳机不在盒内系统不上报），如实少一行
    public static func airPodsSummary(_ battery: AirPodsBattery) -> String {
        var parts = ["左耳 \(battery.left)%", "右耳 \(battery.right)%"]
        if let podCase = battery.case {
            parts.append("充电盒 \(podCase)%")
        }
        return parts.joined(separator: " · ")
    }
}
