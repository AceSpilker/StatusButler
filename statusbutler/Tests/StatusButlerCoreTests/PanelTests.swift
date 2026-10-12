import Combine
import Foundation
import Testing
@testable import StatusButlerCore

// T-030: 弹层面板（分区布局模型 / VM 防抖与旁路启停）。UI 视图本身不测，
// 时间相关用例用宽松阈值等待（防抖窗 500ms、旁路轮询注入短间隔）
@MainActor
@Suite struct PanelTests {

    // MARK: - 测试假件

    /// 蓝牙旁路假件：记录读取次数（启停标志的行为证据）
    @MainActor
    final class FakeBluetoothMonitor: BluetoothMonitoring {
        var devices: [BluetoothDeviceInfo] = [
            BluetoothDeviceInfo(name: "Magic Keyboard", address: "aa-0", kind: .keyboard, isConnected: true),
            BluetoothDeviceInfo(name: "AirPods", address: "bb-1", kind: .headphone, isConnected: false),
        ]
        private(set) var readCount = 0
        func read() async -> [BluetoothDeviceInfo] {
            readCount += 1
            return devices
        }
    }

    /// 温度旁路假件
    @MainActor
    final class FakeThermalMonitor: ThermalMonitoring {
        var snapshot: ThermalSnapshot? = ThermalSnapshot(
            fans: [FanReading(id: 0, minRPM: 1200, maxRPM: 5500, currentRPM: 1499)],
            sensors: [SensorReading(key: "TC0P", name: "CPU 附近", celsius: 46.5)]
        )
        private(set) var readCount = 0
        func read() async -> ThermalSnapshot? {
            readCount += 1
            return snapshot
        }
    }

    /// 轮转电池假件：每次 read 给出下一档电量，驱动快照连续变更（防抖用例）
    @MainActor
    final class RotatingBatteryMonitor: BatteryMonitoring {
        private var index = 0
        private let levels: [Int]
        init(_ levels: [Int]) { self.levels = levels }
        func read() async -> BatteryState {
            defer { index = (index + 1) % levels.count }
            return .battery(level: levels[index], charging: false)
        }
    }

    private func makeStore(battery: some BatteryMonitoring) -> SystemStatusStore {
        SystemStatusStore(
            battery: battery,
            wifi: StaticWiFiMonitor(.wired),
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
    }

    // MARK: - PanelLayout

    @Test func layoutDefaultsAreValidAndComplete() {
        #expect(PanelLayout.default.isValid)
        #expect(PanelLayout.default.order == PanelSectionID.allCases)
        #expect(PanelLayout.default.visibleSections == PanelSectionID.allCases)
        #expect(PanelLayout.default.order.count == PanelSectionID.allCases.count)
    }

    @Test func layoutCodableRoundtripPreservesCustomLayout() throws {
        let custom = PanelLayout(
            visibleSections: [.thermal, .battery],
            order: [.performance, .thermal, .volume, .network, .bluetooth, .battery]
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(PanelLayout.self, from: data)
        #expect(decoded == custom)
    }

    @Test func layoutDecodeRejectsUnknownSectionID() {
        // 旧数据被手改/损坏出现未知分区 id：解码即失败，调用方回退 default/sanitized
        let json = #"{"visibleSections":["battery"],"order":["battery","nfc"]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8))
        }
    }

    @Test func layoutValidationRejectsOrderMissingSection() {
        let layout = PanelLayout(
            visibleSections: [.network],
            order: Array(PanelSectionID.allCases.dropFirst())  // 缺 battery
        )
        #expect(!layout.isValid)
    }

    @Test func layoutValidationRejectsVisibleOutsideOrder() {
        let layout = PanelLayout(
            visibleSections: [.battery, .network],
            order: PanelSectionID.allCases.filter { $0 != .network }  // network 未参与排序
        )
        #expect(!layout.isValid)
    }

    @Test func layoutValidationRejectsDuplicateOrderEntry() {
        var order = PanelSectionID.allCases
        order.append(.volume)
        let layout = PanelLayout(visibleSections: [.volume], order: order)
        #expect(!layout.isValid)
    }

    @Test func sanitizedRepairsBrokenLayoutIntoValidOne() {
        let broken = PanelLayout(
            visibleSections: [.thermal, .thermal, .volume],
            order: [.volume, .volume, .battery]  // 重复 + 缺 4 个分区
        )
        let repaired = broken.sanitized()
        #expect(repaired.isValid)
        #expect(repaired.order.starts(with: [.volume, .battery]))  // 保序去重，缺失按声明序补尾
        #expect(repaired.visibleSections == [.thermal, .volume])
        // 合法布局净化后不变（幂等）
        #expect(PanelLayout.default.sanitized() == .default)
    }

    // MARK: - PanelSectionID

    @Test func allSectionIDsHaveNonEmptyDisplayName() {
        #expect(PanelSectionID.allCases.count == 6)
        for id in PanelSectionID.allCases {
            #expect(!id.displayName.isEmpty, "分区 \(id.rawValue) 标题为空")
        }
    }

    @Test func allSectionIDsHaveNonEmptySymbolName() {
        for id in PanelSectionID.allCases {
            #expect(!id.symbolName.isEmpty, "分区 \(id.rawValue) 图标名为空")
        }
    }

    // MARK: - PanelViewModel：快照 500ms 防抖

    @Test func snapshotUpdatesCoalesceThroughDebounce() async throws {
        let store = makeStore(battery: RotatingBatteryMonitor([11, 22, 33, 44]))
        let vm = PanelViewModel(
            store: store,
            bluetooth: FakeBluetoothMonitor(),
            thermal: FakeThermalMonitor(),
            bypassPollInterval: .seconds(60)  // 旁路关闭（不可见），不影响本用例
        )
        #expect(vm.displaySnapshot == .empty)

        var emissions: [StatusSnapshot] = []
        // @Published 订阅即回放当前值：dropFirst 排除回放的 .empty，只统计防抖后的真实下发
        let cancellable = vm.$displaySnapshot.dropFirst().sink { emissions.append($0) }
        // 慢机兼容：等订阅期回放与 VM 初始赋值全部落定后再清零计数，
        // 否则初始 .empty 可能在订阅后才到（CI 实测），多出一次下发
        try await Task.sleep(for: .milliseconds(200))
        emissions.removeAll()

        // 500ms 窗口内 3 次快照变更（11/22/33）→ 只应合并下发一次末值
        await store.refresh()
        await store.refresh()
        await store.refresh()
        try await Task.sleep(for: .milliseconds(900))  // 越过 500ms 防抖窗

        #expect(emissions.count == 1, "3 次变更应合并为 1 次下发，实际 \(emissions.count)")
        #expect(emissions.first?.battery == .battery(level: 33, charging: false))
        #expect(vm.displaySnapshot.battery == .battery(level: 33, charging: false))

        // 静默期过后再来一次变更 → 再下发一次（防抖不吞掉间隔后的更新）
        await store.refresh()
        try await Task.sleep(for: .milliseconds(900))
        #expect(emissions.count == 2)
        #expect(emissions.last?.battery == .battery(level: 44, charging: false))

        cancellable.cancel()
    }

    // MARK: - PanelViewModel：旁路启停（能效纪律）

    @Test func bypassSamplingStartsWhenPopoverBecomesVisible() async throws {
        let bluetooth = FakeBluetoothMonitor()
        let thermal = FakeThermalMonitor()
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: bluetooth,
            thermal: thermal,
            bypassPollInterval: .seconds(60)
        )
        #expect(vm.popoverVisible == false)
        #expect(!vm.isBypassSamplingActive)  // 不可见绝不采样

        vm.panelDidAppear()  // SwiftUI onAppear 钩子
        #expect(vm.popoverVisible == true)
        #expect(vm.isBypassSamplingActive)

        try await Task.sleep(for: .milliseconds(150))  // 等"打开即读一次"落地
        #expect(bluetooth.readCount >= 1)
        #expect(thermal.readCount >= 1)
        #expect(vm.bluetoothDevices == bluetooth.devices)
        #expect(vm.thermal == thermal.snapshot)
    }

    @Test func bypassSamplingStopsWhenPopoverHidden() async throws {
        let bluetooth = FakeBluetoothMonitor()
        let thermal = FakeThermalMonitor()
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: bluetooth,
            thermal: thermal,
            bypassPollInterval: .milliseconds(60)
        )
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(300))
        let bluetoothReads = bluetooth.readCount
        let thermalReads = thermal.readCount
        #expect(bluetoothReads >= 2)  // 短间隔下应已轮询多轮
        #expect(thermalReads >= 2)

        vm.panelWillDisappear()  // SwiftUI onDisappear 钩子
        #expect(vm.popoverVisible == false)
        #expect(!vm.isBypassSamplingActive)

        try await Task.sleep(for: .milliseconds(150))  // 让可能的 in-flight 读取收尾
        let frozenBluetooth = bluetooth.readCount
        let frozenThermal = thermal.readCount
        try await Task.sleep(for: .milliseconds(200))  // 再越过一个完整轮询周期
        #expect(bluetooth.readCount == frozenBluetooth, "close 后蓝牙不应再采样")
        #expect(thermal.readCount == frozenThermal, "close 后温度不应再采样")
    }

    @Test func bypassPollsRepeatedlyWhileVisible() async throws {
        let bluetooth = FakeBluetoothMonitor()
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: bluetooth,
            thermal: FakeThermalMonitor(),
            bypassPollInterval: .milliseconds(50)
        )
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(800))
        #expect(bluetooth.readCount >= 3, "可见期间应粗间隔轮询，实际 \(bluetooth.readCount) 次")
    }

    @Test func visibilityReportsAreIdempotentThroughTracker() async throws {
        let tracker = PopoverVisibilityTracker()
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: FakeBluetoothMonitor(),
            thermal: FakeThermalMonitor(),
            visibilityTracker: tracker,
            bypassPollInterval: .milliseconds(80)
        )
        // 双通道重复上报（onAppear 与 NSPopover didShow 同时来）：状态仍一致、采样单链
        tracker.setVisible(true)
        vm.panelDidAppear()
        #expect(vm.popoverVisible == true)
        #expect(vm.isBypassSamplingActive)

        tracker.setVisible(false)
        vm.panelWillDisappear()
        tracker.setVisible(false)  // 第三次重复
        #expect(vm.popoverVisible == false)
        #expect(!vm.isBypassSamplingActive)
    }

    // MARK: - PanelViewModel：布局

    @Test func sectionsRenderRespectCustomOrderAndVisibility() {
        let layout = PanelLayout(
            visibleSections: [.thermal, .bluetooth, .battery],
            order: [.performance, .thermal, .volume, .network, .bluetooth, .battery]
        )
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: FakeBluetoothMonitor(),
            thermal: FakeThermalMonitor(),
            layout: layout
        )
        #expect(vm.sectionsToRender == [.thermal, .bluetooth, .battery])
    }

    @Test func applyRejectsInvalidLayoutButAcceptsValid() {
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: FakeBluetoothMonitor(),
            thermal: FakeThermalMonitor()
        )
        let invalid = PanelLayout(visibleSections: [.battery], order: [.battery])  // order 不全
        vm.apply(layout: invalid)
        #expect(vm.layout == .default)

        let reordered = PanelLayout(
            visibleSections: [.volume],
            order: PanelSectionID.allCases.reversed()
        )
        vm.apply(layout: reordered)
        #expect(vm.layout == reordered)
        #expect(vm.sectionsToRender == [.volume])
    }

    @Test func initSanitizesBrokenLayoutInsteadOfDropping() {
        let broken = PanelLayout(visibleSections: [.network], order: [.network])
        let vm = PanelViewModel(
            store: makeStore(battery: StaticBatteryMonitor(.unavailable)),
            bluetooth: FakeBluetoothMonitor(),
            thermal: FakeThermalMonitor(),
            layout: broken
        )
        // 净化补全 order，保住用户"显示网络分区"的选择
        #expect(vm.layout.isValid)
        #expect(vm.sectionsToRender == [.network])
    }
}
