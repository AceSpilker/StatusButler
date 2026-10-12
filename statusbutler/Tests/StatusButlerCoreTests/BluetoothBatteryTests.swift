import Testing
import Foundation
@testable import StatusButlerCore

// T-023b: 蓝牙电量两源合并 —— pmset 配件电源报告解析（fixture 注入）+ AirPods 三值聚合 +
// 合并规则（精确命中/分体并入/孤行生成/HID 优先）+ 真机 pmset 冒烟（只断言键值形态）
@Suite struct BluetoothBatteryTests {
    // MARK: - pmset 解析

    @Test func parseTypicalAccessoryFixture() {
        // 真实 pmset -g ps 的典型混排：本机电池行（含制表符与剩余时间）+ 外设行
        let fixture = """
            Now drawing from 'AC Power'
             -InternalBattery-0 (id=4990533)\t85%; discharging; 3:12 remaining present: true
            Magic Mouse: 88%
            Magic Keyboard: 100%
            """
        #expect(AccessoryBatterySource.parse(stdout: fixture) == ["Magic Mouse": 88, "Magic Keyboard": 100])
    }

    @Test func parseDropsInternalBatteryRow() {
        // 只有本机电池行时必须返回空表——本机电量属于充电域，绝不混入配件表
        let fixture = " -InternalBattery-0 (id=1)\t42%; discharging; 1:00 remaining present: true"
        #expect(AccessoryBatterySource.parse(stdout: fixture).isEmpty)
    }

    @Test func parseAirPodsSplitLineIntoPodKeys() {
        // AirPods 报告形态：设备名行（无百分比，跳过）+ 三仓位同行混排
        let fixture = """
            Now drawing from 'Battery Power'
            AirPods Pro:
            Left: 88% Right: 76% Case: 55%
            """
        #expect(AccessoryBatterySource.parse(stdout: fixture) == ["Left": 88, "Right": 76, "Case": 55])
    }

    @Test func parseSkipsMalformedLines() {
        // 异常行：无配对/负值/缺 %/数字与 % 之间有空格——全部跳过，不产出任何键
        let fixture = """
            garbage line without battery
            Battery: -5%
            NoPercentSign: 88
            Misaligned: 88 %%
            """
        #expect(AccessoryBatterySource.parse(stdout: fixture).isEmpty)
    }

    @Test func parseDropsOutOfRangePercentButKeepsValidRow() {
        // 越界百分比（150）当异常丢弃，同表合法行（88）保留
        let table = AccessoryBatterySource.parse(stdout: "Magic Mouse: 88%\nBroken: 150%")
        #expect(table == ["Magic Mouse": 88])
    }

    @Test func parseEmptyOrNoAccessoryOutputIsEmpty() {
        // 空输出与"只有电源来源行"（无蓝牙机/无在线配件的常态）都返回空表
        #expect(AccessoryBatterySource.parse(stdout: "").isEmpty)
        #expect(AccessoryBatterySource.parse(stdout: "Now drawing from 'AC Power'\n").isEmpty)
    }

    // MARK: - AirPods 三值聚合

    @Test func airPodsAggregatesThreeValuesWithMinPercent() {
        let battery = AccessoryBatterySource.airPods(from: ["Left": 88, "Right": 76, "Case": 55])
        #expect(battery == AirPodsBattery(left: 88, right: 76, case: 55))
        // min 策略：显示最差仓位
        #expect(battery?.percent == 55)
    }

    @Test func airPodsWithoutCaseKeepsNilAndMinOfEars() {
        // 缺盒（耳机不在盒内是常态）：case 为 nil，按双耳取 min
        let battery = AccessoryBatterySource.airPods(from: ["Left": 30, "Right": 90])
        #expect(battery?.case == nil)
        #expect(battery?.percent == 30)
    }

    @Test func airPodsRequiresBothEars() {
        // 双耳不齐不聚合：缺任一耳返回 nil（交由合并层降级），盒电量孤值同样不构成整体
        #expect(AccessoryBatterySource.airPods(from: ["Left": 88, "Case": 55]) == nil)
        #expect(AccessoryBatterySource.airPods(from: ["Right": 76]) == nil)
        #expect(AccessoryBatterySource.airPods(from: [:]) == nil)
    }

    @Test func airPodsPercentFollowsWorstComponent() {
        // min 策略覆盖任意仓位最差的情形
        #expect(AirPodsBattery(left: 90, right: 95, case: 12).percent == 12)
        #expect(AirPodsBattery(left: 5, right: 95).percent == 5)
    }

    // MARK: - 合并规则

    @Test func exactNameMatchTakesPMSetValue() {
        // 规则一：名称精确匹配取 pmset 值；无匹配设备电量为 nil；匹配键不外漏成孤行
        let devices = [
            BluetoothDeviceInfo(name: "Magic Mouse", address: "aa", kind: .mouse, isConnected: true),
            BluetoothDeviceInfo(name: "Magic Keyboard", address: "bb", kind: .keyboard, isConnected: true),
        ]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Magic Mouse": 88])
        #expect(rows.map(\.info.name) == ["Magic Mouse", "Magic Keyboard"])
        #expect(rows[0].batteryPercent == 88)
        #expect(rows[1].batteryPercent == nil)
        #expect(rows.allSatisfy { $0.airPods == nil })
    }

    @Test func unmatchedAccessoryBecomesOrphanOtherRow() {
        // 规则三：无匹配设备的孤立配件行生成 .other 行；地址拿不到就用配件名当唯一键
        let devices = [BluetoothDeviceInfo(name: "Magic Mouse", address: "aa", kind: .mouse, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Magic Mouse": 88, "Jabra Speak 510": 55])
        #expect(rows.count == 2)
        let orphan = rows[1]
        #expect(orphan.info.name == "Jabra Speak 510")
        #expect(orphan.info.kind == .other)
        #expect(orphan.info.isConnected)
        #expect(!orphan.info.address.isEmpty)
        #expect(orphan.batteryPercent == 55)
    }

    @Test func orphanRowsSortedByNameForStableOutput() {
        // 字典无序：孤立行按名称排序，保证同输入同输出
        let rows = BatteryMerge.merge(devices: [], accessoryLevels: ["Zeta": 10, "Alpha": 20, "Mid": 30])
        #expect(rows.map(\.info.name) == ["Alpha", "Mid", "Zeta"])
        #expect(rows.map(\.batteryPercent) == [20, 30, 10])
    }

    @Test func airPodsSplitMergesIntoNamedAirPodsDevice() {
        // 规则二：分体行并入 AirPods 设备（聚合三值 + min），仓位键不生成孤行，其他设备不受牵连
        let devices = [
            BluetoothDeviceInfo(name: "AirPods Pro", address: "aa", kind: .headphone, isConnected: true),
            BluetoothDeviceInfo(name: "Magic Mouse", address: "bb", kind: .mouse, isConnected: true),
        ]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Left": 88, "Right": 76, "Case": 55])
        #expect(rows.count == 2)
        #expect(rows[0].airPods == AirPodsBattery(left: 88, right: 76, case: 55))
        #expect(rows[0].batteryPercent == 55)
        #expect(rows[1].airPods == nil)
        #expect(rows[1].batteryPercent == nil)
    }

    @Test func airPodsSplitFallsBackToHeadphoneKindDevice() {
        // 设备名不带 "AirPods"（Beats 等同形态分体上报耳机）：耳机类设备接手分体值
        let devices = [BluetoothDeviceInfo(name: "Beats Fit Pro", address: "aa", kind: .headphone, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Left": 88, "Right": 76])
        #expect(rows.count == 1)
        #expect(rows[0].airPods == AirPodsBattery(left: 88, right: 76))
        #expect(rows[0].batteryPercent == 76)
    }

    @Test func airPodsSplitWithoutDeviceSynthesizesHeadphoneRow() {
        // 设备清单缺席（快照竞态）：分体值兜底为一条耳机行，而不是拆成 Left/Right 孤行
        let rows = BatteryMerge.merge(devices: [], accessoryLevels: ["Left": 88, "Right": 76, "Case": 55])
        #expect(rows.count == 1)
        #expect(rows[0].info.kind == .headphone)
        #expect(rows[0].airPods == AirPodsBattery(left: 88, right: 76, case: 55))
        #expect(rows[0].batteryPercent == 55)
    }

    @Test func connectedAirPodsPreferredOverDisconnected() {
        // "最近"：在线优先——pmset 只对在线设备上报电量，离线的 AirPods Max 不吃分体值
        let devices = [
            BluetoothDeviceInfo(name: "AirPods Max", address: "aa", kind: .headphone, isConnected: false),
            BluetoothDeviceInfo(name: "AirPods Pro", address: "bb", kind: .headphone, isConnected: true),
        ]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Left": 88, "Right": 76])
        #expect(rows[0].airPods == nil)
        #expect(rows[1].airPods == AirPodsBattery(left: 88, right: 76))
    }

    @Test func partialPodReportDegradesToSingleValue() {
        // pmset 偶发只报单仓位：聚合不成三值也并入候选设备，降级为该仓位电量，仓位行不孤行外漏
        let devices = [BluetoothDeviceInfo(name: "AirPods Pro", address: "aa", kind: .headphone, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Left": 88])
        #expect(rows.count == 1)
        #expect(rows[0].airPods == nil)
        #expect(rows[0].batteryPercent == 88)
    }

    @Test func hidDevicePrefersSystemValueOverExtra() {
        // 规则四：HID 类（键鼠/触控板/手柄）两源冲突时信 pmset 系统报告——与系统设置展示一致
        let devices = [BluetoothDeviceInfo(name: "Magic Mouse", address: "aa", kind: .mouse, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Magic Mouse": 60], extra: ["Magic Mouse": 70])
        #expect(rows[0].batteryPercent == 60)
    }

    @Test func nonHIDDevicePrefersExtraValue() {
        // 非 HID：第二源是更直接的读数，pmset 退居兜底
        let devices = [BluetoothDeviceInfo(name: "Beats Fit Pro", address: "aa", kind: .headphone, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Beats Fit Pro": 60], extra: ["Beats Fit Pro": 70])
        #expect(rows[0].batteryPercent == 70)
    }

    @Test func extraFillsDevicesPMSetLacks() {
        // 第二源补 pmset 没覆盖的设备；单源场景（extra 缺键）退化为 pmset 精确匹配
        let devices = [
            BluetoothDeviceInfo(name: "Magic Mouse", address: "aa", kind: .mouse, isConnected: true),
            BluetoothDeviceInfo(name: "SoundLink", address: "bb", kind: .speaker, isConnected: true),
        ]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: ["Magic Mouse": 88], extra: ["SoundLink": 44])
        #expect(rows[0].batteryPercent == 88)
        #expect(rows[1].batteryPercent == 44)
    }

    @Test func extraDoesNotFabricateRows() {
        // 第二源只补值不造行：清单外的 extra 键不能凭空长出设备
        let devices = [BluetoothDeviceInfo(name: "Magic Mouse", address: "aa", kind: .mouse, isConnected: true)]
        let rows = BatteryMerge.merge(devices: devices, accessoryLevels: [:], extra: ["Ghost Device": 10])
        #expect(rows.count == 1)
        #expect(rows[0].info.name == "Magic Mouse")
    }

    @Test func mergedRowValueSemantics() {
        // 值类型折叠语义：等值比较按全字段（info + 电量 + AirPods 明细）
        let info = BluetoothDeviceInfo(name: "X", address: "aa", kind: .mouse, isConnected: true)
        let a = BluetoothDeviceWithBattery(info: info, batteryPercent: 80)
        #expect(a == BluetoothDeviceWithBattery(info: info, batteryPercent: 80))
        #expect(a != BluetoothDeviceWithBattery(info: info, batteryPercent: 81))
        #expect(a != BluetoothDeviceWithBattery(info: info, batteryPercent: 80, airPods: AirPodsBattery(left: 1, right: 2)))
    }

    // MARK: - live 冒烟

    @Test func livePMSetReadReturnsValidTable() async {
        // 冒烟只断言键值形态：无蓝牙/无在线配件的机器（CI、台式）返回空表也必须通过
        let table = await AccessoryBatterySource().read()
        for (name, percent) in table {
            #expect(!name.isEmpty)
            #expect((0...100).contains(percent))
        }
    }

    @Test func readUsesInjectedProviderOutput() async {
        // 注入假命令输出：不触系统即可验证 collect→parse 全链路
        let source = AccessoryBatterySource(collect: { "Magic Mouse: 88%" })
        #expect(await source.read() == ["Magic Mouse": 88])
    }

    @Test func readFailureFoldsToEmptyTable() async {
        // 命令执行失败按无配件收敛，监控路径不抛错
        struct Boom: Error {}
        let source = AccessoryBatterySource(collect: { throw Boom() })
        #expect(await source.read().isEmpty)
    }
}
