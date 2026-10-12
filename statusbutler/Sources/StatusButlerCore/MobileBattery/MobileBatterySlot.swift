import Foundation

// T-053 面板数据桥（iDevice 电量）：接入说明——为什么这批数据不进 StatusSnapshot。
//
// 架构铁律三的适用：StatusSnapshot 的相等性是图标渲染缓存 key（"快照相等 = 图标不变"），
// 只有能画进菜单栏/Dock 图标的状态才允许进快照。iDevice 电量是纯面板信息
// （用户插上 iPhone 才看一眼），画不进图标；塞进快照会让每次插拔设备都击穿
// 图标缓存重绘，还把 usbmuxd 往返拉进常驻采样链——所以走旁路，与蓝牙/温度同归
// PanelViewModel 的旁路数据类（出现即读一次 + 消失即停，绝不常驻轮询）。
//
// 接线路径（T-053b 面板半场）：
//   1. 组合根构造 MobileBatteryHelperReader，helper 路径注入 .app 内绝对路径
//      （开发态默认 .build/mobile-battery/statusbutler-mobilebattery）；
//   2. PanelViewModel 增设 mobileBattery 旁路：panelDidAppear 时 await reader.read()
//      一次，随后按 defaultBypassPollInterval 粗间隔续采，panelWillDisappear 即 cancel；
//   3. 读取结果折叠成 MobileBatterySummary 驱动面板设备行；status == .unavailable
//      时展示"未构建 iDevice helper"引导文案（scripts/build-mobile-battery-helper.sh），
//      不是错误态；
//   4. 绝不写进 StatusSnapshot，也绝不进菜单栏/Dock 图标渲染键——本类型存在的
//      意义就是把这条边界做成显式类型，而非散落的注释。

/// iDevice 电量面板汇总：设备的只读清单 + 总数。
/// 只服务面板展示（旁路），不是监控域状态容器——充电域/本机电池有自己的模型
public struct MobileBatterySummary: Equatable, Sendable {
    public let devices: [MobileBatteryDevice]

    /// 设备总数。计算属性而非存储字段：与 devices.count 恒等，避免两处真相
    public var total: Int { devices.count }

    public init(devices: [MobileBatteryDevice]) {
        self.devices = devices
    }

    /// 从一轮读取折叠：helper 不可用（未构建/执行失败）时给空汇总，
    /// 面板据此走引导文案分支而不是渲染残缺列表
    public init(reading: MobileBatteryReading) {
        self.init(devices: reading.status == .available ? reading.devices : [])
    }

    public static let empty = MobileBatterySummary(devices: [])
}
