// TODO(T-023b 电池源): IOBluetooth 公开 API 不暴露每设备电量 —— 规格走"配对报告为主源、
// pmset 配件电源报告补缺"（AirPods 三仓位电量另算）两源取数，本文件不造任何电量数据，
// 读路径只报名称/地址/种类/连接态。
//
// T-023 范围是纯读取：每次 read() 后台一次性快照，不缓存、不订阅通知、绝不连接/断开
// （设备操作与事件驱动刷新属后续 UI 任务）。

import IOBluetooth

/// 蓝牙域监控协议（沿用 `-ing` 后缀惯例，便于面板/测试注入假实现；
/// 本任务禁止改动 MonitorProtocols.swift，故随域文件新增）
public protocol BluetoothMonitoring: Sendable {
    func read() async -> [BluetoothDeviceInfo]
}

/// 无状态监控器：IOBluetooth 的 ObjC 查询可能同步往返 bluetoothd（阻塞调用），
/// 因此全部取值放进 detached 后台任务，折叠成值类型数组后才回流调用方隔离域，
/// ObjC 对象引用绝不跨越并发边界。
public struct BluetoothMonitor: Sendable, BluetoothMonitoring {
    public init() {}

    public func read() async -> [BluetoothDeviceInfo] {
        await Task.detached(priority: .utility) {
            Self.snapshot()
        }.value
    }

    private static func snapshot() -> [BluetoothDeviceInfo] {
        // 无蓝牙模块的台式机、或蓝牙整体关闭时，pairedDevices() 返回 nil/空 —— 如实报空数组，
        // 面板对"无蓝牙"与"零配对"的文案区分不在监控层
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        return paired.map { device in
            let cod = device.classOfDevice
            return BluetoothDeviceInfo(
                name: device.name ?? "",
                address: device.addressString ?? "",
                kind: BluetoothDeviceKind.kind(
                    ofDeviceClass: (major: (cod >> 8) & 0x1F, minor: (cod >> 2) & 0x3F)
                ),
                isConnected: device.isConnected()
            )
        }
    }
}
