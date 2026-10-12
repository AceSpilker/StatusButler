// T-023b 蓝牙电量两源合并：IOBluetooth 设备清单（有地址/种类/连接态、无电量）与 pmset 配件表
// （有电量、无地址无连接态）各缺一半字段，此处合成面板可用的"设备+电量"行。全部纯函数，无状态无 IO。
//
// 两源冲突裁决：HID 类（键盘/鼠标/触控板/手柄）信 pmset 系统报告——那是系统设置界面展示的同一读数；
// 其余设备信第二源——pmset 对非 HID 配件的覆盖不稳，第二源给出值时视为更直接的读数，pmset 退居兜底。
// 第二源只补设备行的值：不造行、不改写孤立行——不受控来源的键不能凭空长出设备。

/// 合并结果行：info 来自设备清单或孤立配件行合成；电量两可空——两源皆缺时 nil，面板显示"电量未知"
public struct BluetoothDeviceWithBattery: Equatable, Sendable {
    public let info: BluetoothDeviceInfo
    /// 整机显示电量（AirPods 类为 min 策略聚合值）
    public let batteryPercent: Int?
    /// 仅 AirPods 类分体上报设备非空：三仓位明细，供面板展开显示
    public let airPods: AirPodsBattery?

    public init(info: BluetoothDeviceInfo, batteryPercent: Int?, airPods: AirPodsBattery? = nil) {
        self.info = info
        self.batteryPercent = batteryPercent
        self.airPods = airPods
    }
}

/// 合并引擎（纯函数命名空间）
public enum BatteryMerge {
    /// pmset 分体行拆出的仓位键（小写比对）——pmset 固定输出 "Left:/Right:/Case:" 三个词，
    /// 与真实设备名 "xx-Left-Speaker" 之类不会撞车
    private static let podKeys: Set<String> = ["left", "right", "case"]

    /// 两源裁决：HID 听系统（与系统设置展示一致），其余听第二源（读数更直接）
    private static func resolveBattery(kind: BluetoothDeviceKind, pmsetValue: Int?, extraValue: Int?) -> Int? {
        switch kind {
        case .keyboard, .mouse, .trackpad, .gamepad:
            return pmsetValue ?? extraValue
        case .headphone, .speaker, .wearable, .other:
            return extraValue ?? pmsetValue
        }
    }

    /// "最近 AirPods 设备"：点名 AirPods 的优先于泛耳机类；同类在线优先（pmset 只上报在线设备）；
    /// 同优先级取清单序首个——IOBluetooth 快照顺序稳定，保证同输入同输出
    private static func airPodsCandidateIndex(in devices: [BluetoothDeviceInfo]) -> Int? {
        let named = devices.indices.filter { devices[$0].name.lowercased().contains("airpods") }
        let headphones = devices.indices.filter { devices[$0].kind == .headphone }
        return named.first { devices[$0].isConnected }
            ?? named.first
            ?? headphones.first { devices[$0].isConnected }
            ?? headphones.first
    }

    /// - Parameters:
    ///   - devices: IOBluetooth 设备清单（T-023 读路径产物，无电量）
    ///   - accessoryLevels: pmset 配件电量表（AccessoryBatterySource.parse 产物）
    ///   - extra: 可选第二源（设备名→电量）；nil 时退化为单源精确匹配
    public static func merge(
        devices: [BluetoothDeviceInfo],
        accessoryLevels: [String: Int],
        extra: [String: Int]? = nil
    ) -> [BluetoothDeviceWithBattery] {
        let extra = extra ?? [:]
        var consumed = Set<String>()
        var rows: [BluetoothDeviceWithBattery] = []

        let splitEntries = accessoryLevels.filter { podKeys.contains($0.key.lowercased()) }
        let aggregate = AccessoryBatterySource.airPods(from: accessoryLevels)
        let candidateIndex = airPodsCandidateIndex(in: devices)

        for (index, device) in devices.enumerated() {
            let pmsetValue = accessoryLevels[device.name]
            let extraValue = extra[device.name]

            if index == candidateIndex, !splitEntries.isEmpty {
                // 分体行并入最近 AirPods 设备：双耳齐则聚合三值（min 策略）；pmset 偶发只报单仓位时
                // 降级为该仓位值——仓位行绝不外漏成孤行。同名的整机电量行以分体明细为准
                consumed.formUnion(splitEntries.map { $0.0 })
                consumed.insert(device.name)
                rows.append(BluetoothDeviceWithBattery(
                    info: device,
                    batteryPercent: aggregate?.percent ?? splitEntries.map { $0.1 }.min(),
                    airPods: aggregate
                ))
            } else {
                if pmsetValue != nil { consumed.insert(device.name) }
                rows.append(BluetoothDeviceWithBattery(
                    info: device,
                    batteryPercent: resolveBattery(kind: device.kind, pmsetValue: pmsetValue, extraValue: extraValue)
                ))
            }
        }

        // 孤立配件行：pmset 报了电量但设备清单里没有对应设备（IOBluetooth 快照滞后/非蓝牙配件上报）。
        // 拿不到地址就用配件名当唯一键——真实地址是 "xx-xx-…" 形态不会撞名；在线态按 true
        // （pmset 只对在线设备上报）。字典无序，按名称排序保证输出稳定可测
        let orphans = accessoryLevels
            .filter { !consumed.contains($0.key) && !podKeys.contains($0.key.lowercased()) }
            .sorted { $0.key < $1.key }
        for (name, percent) in orphans {
            rows.append(BluetoothDeviceWithBattery(
                info: BluetoothDeviceInfo(name: name, address: name, kind: .other, isConnected: true),
                batteryPercent: percent
            ))
        }

        // 分体值找不到归属设备（快照竞态）：兜底合成一条耳机行，比拆成 Left/Right 孤行更有面板意义
        if candidateIndex == nil, !splitEntries.isEmpty {
            rows.append(BluetoothDeviceWithBattery(
                info: BluetoothDeviceInfo(name: "AirPods", address: "AirPods", kind: .headphone, isConnected: true),
                batteryPercent: aggregate?.percent ?? splitEntries.map { $0.1 }.min(),
                airPods: aggregate
            ))
        }

        return rows
    }
}
