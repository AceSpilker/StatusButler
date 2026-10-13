import AppKit
import Foundation
import os
import Testing

@testable import StatusButlerCore

// A14-β 弹层全量·VM 集成测试：导航栈/扫描流/音量写节流/滚动/徽标点亮/蓝牙操作/
// 动作行/天气日程隐藏/槽位轮换/深链出口。时间敏感用例给足 CI 负载余量。
// 窗口类用例（NSPopover 壳）按 AGENTS 实战经验加能力守卫：无 WindowServer 的 CI 跳过。
// 假件遵循 PanelTests 的既有姿势：VM 全链 MainActor，@MainActor 类即可安全记录调用
@MainActor
@Suite(.serialized)
struct PanelCompleteTests {

    // MARK: - 测试假件

    @MainActor
    final class FakeVolumeWriter: VolumeWriting {
        private(set) var levels: [Int] = []
        func write(level: Int) async { levels.append(level) }
    }

    struct FakeScanner: WiFiScanning {
        let networks: [NearbyNetwork]
        func scan() async -> [NearbyNetwork] { networks }
    }

    @MainActor
    final class CountingScanner: WiFiScanning {
        private(set) var scanCount = 0
        func scan() async -> [NearbyNetwork] {
            scanCount += 1
            try? await Task.sleep(for: .milliseconds(150))
            return []
        }
    }

    struct FakeAddressReader: InterfaceAddressReading {
        let addresses: [InterfaceAddressInfo]
        init(_ addresses: [InterfaceAddressInfo]) { self.addresses = addresses }
        func read() async -> [InterfaceAddressInfo] { addresses }
    }

    struct FakeBatteryDetailsReader: BatteryDetailsReading {
        let details: BatteryDetails?
        init(_ details: BatteryDetails?) { self.details = details }
        func read() async -> BatteryDetails? { details }
    }

    struct FakeConnectionProvider: ConnectionDetailsProviding {
        let details: ConnectionDetails
        func read() async -> ConnectionDetails { details }
    }

    struct FakeBluetoothBatterySource: BluetoothBatteryMerging {
        let rows: [BluetoothDeviceWithBattery]
        init(_ rows: [BluetoothDeviceWithBattery]) { self.rows = rows }
        func read() async -> [BluetoothDeviceWithBattery] { rows }
    }

    struct BluetoothCall: Equatable {
        let address: String
        let connected: Bool
    }

    @MainActor
    final class RecordingBluetoothOperator: BluetoothOperating {
        func connect(address: String) async -> Bool { await setConnected(true, address: address) }
        func disconnect(address: String) async -> Bool { await setConnected(false, address: address) }

        private(set) var calls: [BluetoothCall] = []
        let result: Bool
        init(result: Bool = true) { self.result = result }
        func setConnected(_ connected: Bool, address: String) async -> Bool {
            calls.append(BluetoothCall(address: address, connected: connected))
            return result
        }
    }

    /// 动作执行记录器：@Sendable 同步执行闭包可直接触达，锁内计数（call 是同步函数，
    /// 不受 async 上下文锁禁用约束）
    final class RecordingExecutor: @unchecked Sendable {
        // @unchecked 论证：ids 只在 unfair lock 内读写
        private let ids = OSAllocatedUnfairLock(initialState: [String]())
        func call(_ id: String) -> ActionOutcome {
            ids.withLock { $0.append(id) }
            return .performed
        }
        var recorded: [String] { ids.withLock { $0 } }
    }

    /// 深链出口记录器（openExternal 闭包本身是 @MainActor）
    @MainActor
    final class URLRecorder {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
        var last: URL? { urls.last }
    }

    @MainActor
    final class StubBluetoothMonitor: BluetoothMonitoring {
        var devices: [BluetoothDeviceInfo]
        init(_ devices: [BluetoothDeviceInfo]) { self.devices = devices }
        func read() async -> [BluetoothDeviceInfo] { devices }
    }

    @MainActor
    final class StubThermalMonitor: ThermalMonitoring {
        func read() async -> ThermalSnapshot? { nil }
    }

    private func makeStore() -> SystemStatusStore {
        SystemStatusStore(
            battery: StaticBatteryMonitor(.battery(level: 66, charging: false)),
            wifi: StaticWiFiMonitor(.wifi(ssid: "Home", signalBars: 3)),
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
    }

    private func makeVM(
        store: SystemStatusStore? = nil,
        bluetooth: any BluetoothMonitoring = StubBluetoothMonitor([]),
        scanner: (any WiFiScanning)? = nil,
        addresses: (any InterfaceAddressReading)? = nil,
        batteryDetails: (any BatteryDetailsReading)? = nil,
        connection: (any ConnectionDetailsProviding)? = nil,
        volumeWriter: (any VolumeWriting)? = nil,
        volumeWriteMinInterval: TimeInterval = PanelViewModel.defaultVolumeWriteMinInterval,
        naturalScrolling: Bool = true,
        bluetoothOperator: (any BluetoothOperating)? = nil,
        bluetoothBattery: (any BluetoothBatteryMerging)? = nil,
        actions: [ButlerAction] = [],
        actionExecutor: (@Sendable (ButlerAction) -> ActionOutcome)? = nil,
        weatherProvider: WeatherTextProvider? = nil,
        calendarProvider: CalendarTextProvider? = nil,
        healthReportProvider: HealthReportProvider? = nil,
        slotCycler: (any SlotCycling)? = nil,
        openExternal: (@MainActor (URL) -> Void)? = nil
    ) -> PanelViewModel {
        PanelViewModel(
            store: store ?? makeStore(),
            bluetooth: bluetooth,
            thermal: StubThermalMonitor(),
            bypassPollInterval: .seconds(60),  // 单发读即可验证，不轮询
            connectionDetails: connection,
            wifiScanner: scanner,
            interfaceAddresses: addresses,
            batteryDetails: batteryDetails,
            volumeWriter: volumeWriter,
            volumeWriteMinInterval: volumeWriteMinInterval,
            naturalScrolling: naturalScrolling,
            bluetoothOperator: bluetoothOperator,
            bluetoothBattery: bluetoothBattery,
            actions: actions,
            actionExecutor: actionExecutor,
            weatherProvider: weatherProvider,
            calendarProvider: calendarProvider,
            healthReportProvider: healthReportProvider,
            slotCycler: slotCycler,
            openExternal: openExternal
        )
    }

    // MARK: - 导航栈 push/pop

    @Test func navigationStackPushesThreePagesAndPopsInReverseOrder() {
        let vm = makeVM()
        #expect(vm.currentRoute == nil)

        vm.push(.nearbyNetworks)
        vm.push(.linkDetails)
        vm.push(.batteryDetails)
        #expect(vm.routes == [.nearbyNetworks, .linkDetails, .batteryDetails])
        #expect(vm.currentRoute == .batteryDetails)

        vm.pop()
        #expect(vm.currentRoute == .linkDetails)
        vm.pop()
        vm.pop()
        #expect(vm.currentRoute == nil)
        vm.pop()  // 空栈再 pop 是无害幂等
        #expect(vm.routes.isEmpty)
    }

    @Test func popoverDismissResetsNavigationToRoot() {
        let vm = makeVM()
        vm.push(.batteryDetails)
        vm.push(.healthReport)
        vm.panelWillDisappear()
        #expect(vm.routes.isEmpty)  // transient 弹层重开必须回到概览根页
    }

    // MARK: - 附近网络扫描

    @Test func scanNearbyPublishesOrderedResultsAndClearsScanningFlag() async throws {
        let vm = makeVM(scanner: FakeScanner(networks: [
            NearbyNetwork(ssid: "弱", bssid: "a:1", rssi: -80, isSecure: true),
            NearbyNetwork(ssid: "强", bssid: "a:2", rssi: -40, isSecure: false),
        ]))
        vm.push(.nearbyNetworks)  // 首次进入自动扫一轮
        #expect(vm.isScanningNearby)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!vm.isScanningNearby)
        #expect(vm.nearbyNetworks.map(\.ssid) == ["强", "弱"])  // 排序纯函数接线到发布值
    }

    @Test func scanReentryIsGuardedWhileScanning() async throws {
        let scanner = CountingScanner()
        let vm = makeVM(scanner: scanner)
        vm.scanNearbyNetworks()
        vm.scanNearbyNetworks()  // 扫描中的重复点击不叠加任务
        vm.scanNearbyNetworks()
        try await Task.sleep(for: .milliseconds(100))
        #expect(scanner.scanCount == 1)
        try await Task.sleep(for: .milliseconds(600))  // 让 in-flight 收尾，不泄漏到后续用例
    }

    @Test func settingsDeepLinksGoThroughInjectedOutlet() async throws {
        let recorder = URLRecorder()
        let vm = makeVM(openExternal: { recorder.record($0) })
        vm.openWiFiSettings()
        #expect(recorder.last?.absoluteString == PanelDeepLink.wifiSettingsURLString)
        vm.openBatterySettings()
        #expect(recorder.last?.absoluteString == PanelDeepLink.batterySettingsURLString)
    }

    // MARK: - 链路详情与徽标点亮

    @Test func connectionDetailsBypassPollLightsUpNetworkBadges() async throws {
        let vpn = ConnectionDetails(
            isSatisfied: true, isExpensive: false, isConstrained: true,
            isVPN: true, interfaceTypes: [.wifi, .other]
        )
        let vm = makeVM(connection: FakeConnectionProvider(details: vpn))
        #expect(vm.connectionDetails == nil)  // 不可见不采样
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(600))
        #expect(vm.connectionDetails == vpn)
        // 网络行徽标点亮判定（离线/无 VPN 不亮、VPN+受限齐亮）——直接钉 View 内同一纯函数
        #expect(NetworkRow.hasBadge(link: .wifi(ssid: "Home", signalBars: 3), details: vm.connectionDetails))
        #expect(!NetworkRow.hasBadge(link: .offline, details: vm.connectionDetails))
    }

    @Test func linkDetailsPushFetchesAddressesOnce() async throws {
        let vm = makeVM(addresses: FakeAddressReader([
            InterfaceAddressInfo(name: "en0", address: "192.168.1.5", family: .ipv4),
            InterfaceAddressInfo(name: "utun3", address: "10.8.0.2", family: .ipv4),
        ]))
        vm.push(.linkDetails)
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.linkAddresses.count == 2)
        #expect(LinkDetailsFormatting.addressLines(vm.linkAddresses).count == 2)
    }

    // MARK: - 电池详情

    @Test func batteryDetailsPushPublishesReaderOutput() async throws {
        let details = BatteryDetails(
            cycleCount: 312, maxCapacity: 4_802, designCapacity: 5_103,
            voltageMillivolts: 12_160, amperageMilliamps: -1_540,
            externalConnected: true, isCharging: true
        )
        let vm = makeVM(batteryDetails: FakeBatteryDetailsReader(details))
        vm.push(.batteryDetails)
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.batteryDetail == details)
        #expect(BatteryDetailsMapping.healthPercent(
            maxCapacity: vm.batteryDetail?.maxCapacity,
            designCapacity: vm.batteryDetail?.designCapacity
        ) == 94)
    }

    // MARK: - 音量写路径

    @Test func volumeWritesCoalesceThroughThrottle() async throws {
        let writer = FakeVolumeWriter()
        let vm = makeVM(volumeWriter: writer, volumeWriteMinInterval: 0.25)
        #expect(vm.isVolumeWritable)

        vm.setVolume(30)   // 首写立即
        vm.setVolume(40)   // 窗口内 → 尾随
        vm.setVolume(50)   // 窗口内 → 尾随（覆盖前值）
        vm.setVolume(60)   // 窗口内 → 尾随（终值）
        #expect(vm.volumeOverride == 60)  // 乐观显示跟终值

        try await Task.sleep(for: .milliseconds(900))  // 越过冲刷点（CI 负载余量）
        let writes = writer.levels
        #expect(writes.first == 30, "首写应立即落，实际 \(writes)")
        #expect(writes.last == 60, "洪流终点应冲刷末值，实际 \(writes)")
        #expect(writes.count <= 3, "洪流必须合并（≤首值+尾值+偶发分裂），实际 \(writes)")
        #expect(Set(writes).isSubset(of: [30, 40, 50, 60]))
    }

    @Test func scrollVolumeAppliesNaturalScrollingDirectionAndClamps() {
        let vm = makeVM(volumeWriter: FakeVolumeWriter(), volumeWriteMinInterval: 10, naturalScrolling: true)
        // 自然滚动：deltaY<0（手指上扫）调大；初值取自快照（.empty → level 0）
        vm.scrollVolume(deltaY: -6)
        #expect(vm.volumeOverride == ScrollVolumeMapping.defaultStep)
        vm.setVolume(99)
        vm.scrollVolume(deltaY: -6)
        #expect(vm.volumeOverride == 100)  // 顶部钳制

        let legacy = makeVM(volumeWriter: FakeVolumeWriter(), volumeWriteMinInterval: 10, naturalScrolling: false)
        legacy.scrollVolume(deltaY: 6)  // 传统滚动：滚轮上滚调大
        #expect(legacy.volumeOverride == ScrollVolumeMapping.defaultStep)
    }

    @Test func volumeStaysReadOnlyWithoutWriterInjection() async throws {
        let vm = makeVM(volumeWriter: nil)
        #expect(!vm.isVolumeWritable)
        vm.setVolume(80)
        vm.scrollVolume(deltaY: -6)
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.volumeOverride == nil)  // 未接线保持只读，不假装写入
    }

    // MARK: - 蓝牙

    @Test func bluetoothBatterySourceFeedsRowsAndDeviceList() async throws {
        let keyboard = BluetoothDeviceInfo(name: "Magic Keyboard", address: "kb-9", kind: .keyboard, isConnected: true)
        let pods = BluetoothDeviceInfo(name: "AirPods Pro", address: "ap-1", kind: .headphone, isConnected: true)
        let rows = [
            BluetoothDeviceWithBattery(info: keyboard, batteryPercent: 77),
            BluetoothDeviceWithBattery(
                info: pods, batteryPercent: 55,
                airPods: AirPodsBattery(left: 55, right: 61, case: 88)
            ),
        ]
        let vm = makeVM(bluetoothBattery: FakeBluetoothBatterySource(rows))
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(600))
        #expect(vm.bluetoothBatteryRows.count == 2)
        #expect(vm.bluetoothBatteryRows.first?.batteryPercent == 77)
        #expect(vm.bluetoothBatteryRows.last?.airPods?.percent == 55)  // min 显示策略
        #expect(vm.bluetoothDevices.map(\.address) == ["kb-9", "ap-1"])  // 摘要行数据同源
    }

    @Test func hidDisconnectNeedsSecondTapAndNonHIDFiresImmediately() async throws {
        let keyboard = BluetoothDeviceInfo(name: "Magic Keyboard", address: "kb-9", kind: .keyboard, isConnected: true)
        let pods = BluetoothDeviceInfo(name: "AirPods", address: "ap-1", kind: .headphone, isConnected: true)
        let op = RecordingBluetoothOperator()
        let vm = makeVM(bluetooth: StubBluetoothMonitor([keyboard, pods]), bluetoothOperator: op)

        // HID 第一击：只武装不执行
        vm.toggleBluetoothDevice(keyboard)
        #expect(op.calls.isEmpty)
        #expect(vm.hidArmedAddress == "kb-9")
        // HID 第二击：确认执行断开
        vm.toggleBluetoothDevice(keyboard)
        try await Task.sleep(for: .milliseconds(500))
        #expect(op.calls.count == 1)
        #expect(op.calls.first?.connected == false)
        #expect(op.calls.first?.address == "kb-9")
        #expect(vm.hidArmedAddress == nil)
        #expect(vm.lastBluetoothOperation?.succeeded == true)

        // 非 HID（耳机）断开直达，不武装
        vm.toggleBluetoothDevice(pods)
        try await Task.sleep(for: .milliseconds(500))
        #expect(op.calls.count == 2)
        #expect(op.calls.last?.connected == false)
        #expect(op.calls.last?.address == "ap-1")
        #expect(vm.hidArmedAddress == nil)
    }

    @Test func connectingDisconnectedDeviceSkipsConfirmation() async throws {
        let mouse = BluetoothDeviceInfo(name: "Magic Mouse", address: "ms-2", kind: .mouse, isConnected: false)
        let op = RecordingBluetoothOperator()
        let vm = makeVM(bluetooth: StubBluetoothMonitor([mouse]), bluetoothOperator: op)
        vm.toggleBluetoothDevice(mouse)  // 连接动作无需二次确认
        try await Task.sleep(for: .milliseconds(500))
        #expect(op.calls.count == 1)
        #expect(op.calls.first?.connected == true)
        #expect(vm.hidArmedAddress == nil)
    }

    // MARK: - 动作中心行

    @Test func actionsRouteThroughInjectedExecutorAndUnavailableOnesAreRefused() {
        let good = ButlerAction(id: "volume", title: "音量", symbolName: "speaker.wave.2.fill", availability: .available)
        let unsupported = ButlerAction(id: "fan-max", title: "风扇全速", symbolName: "wind", availability: .unavailableOnSystem)
        let recorder = RecordingExecutor()
        let executor: @Sendable (ButlerAction) -> ActionOutcome = { recorder.call($0.id) }
        let vm = makeVM(actions: [good, unsupported], actionExecutor: executor)
        #expect(vm.isActionCenterArmed)

        #expect(vm.perform(good) == .performed)
        #expect(recorder.recorded == ["volume"])
        // "本机不支持"在 VM 层就被拒绝——执行器不背锅
        #expect(vm.perform(unsupported) == nil)
        #expect(recorder.recorded == ["volume"])
        #expect(vm.lastActionOutcome == .performed)
    }

    @Test func actionCenterIsDisarmedWithoutExecutor() {
        let action = ButlerAction(id: "panel", title: "打开面板", symbolName: "square.grid.2x2", availability: .available)
        let vm = makeVM(actions: [action], actionExecutor: nil)
        #expect(!vm.isActionCenterArmed)
        #expect(vm.perform(action) == nil)  // 未接线不伪装执行
    }

    // MARK: - 天气/日程行（nil 隐藏）

    @Test func infoStripHidesWhenProvidersReturnNilAndShowsWithValues() async throws {
        let hidden = makeVM(weatherProvider: { nil }, calendarProvider: { nil })
        hidden.panelDidAppear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hidden.showsInfoStrip)

        let shown = makeVM(weatherProvider: { "26° 晴" }, calendarProvider: { "25分" })
        shown.panelDidAppear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown.showsInfoStrip)
        #expect(shown.weatherText == "26° 晴")
        #expect(shown.calendarText == "25分")
    }

    // MARK: - 体检页

    @Test func healthReportProviderFeedsScoreAndPushRefreshes() async throws {
        let report = HealthReport(results: [
            HealthCheckResult(id: "filevault", title: "FileVault 磁盘加密", status: .pass, detail: "已开启", remediationHint: ""),
            HealthCheckResult(id: "softwareUpdate", title: "系统更新", status: .fail, detail: "有可用更新", remediationHint: "打开 系统设置 → 通用 → 软件更新"),
        ])
        let recorder = URLRecorder()
        let vm = makeVM(healthReportProvider: { report }, openExternal: { recorder.record($0) })
        #expect(vm.showsHealthRow)
        vm.push(.healthReport)
        #expect(vm.healthReport == report)
        #expect(vm.healthReport?.score == 50)
        #expect(HealthScoreTier.tier(forScore: vm.healthReport?.score ?? 0) == .poor)
        // "去修复"深链出口
        vm.openRemediation(checkID: "softwareUpdate")
        #expect(recorder.last?.absoluteString == PanelDeepLink.softwareUpdateURLString)
        vm.openRemediation(checkID: "mystery")  // 无深链安全 no-op
        #expect(recorder.urls.count == 1)
    }

    // MARK: - 槽位 footer

    @Test func slotFooterShowsCurrentSlotAndCyclesOnTap() {
        let vm = makeVM(slotCycler: StaticSlotCycler(labels: ["音量", "时钟", "电池%"]))
        #expect(vm.slotLabel == nil)  // 未出现不读
        vm.panelDidAppear()
        #expect(vm.slotLabel == "音量")
        vm.cycleSlot()
        #expect(vm.slotLabel == "时钟")
        vm.cycleSlot()
        vm.cycleSlot()
        #expect(vm.slotLabel == "音量")  // 回绕
    }

    // MARK: - 深链出口（注入断言）

    @Test func remediationAndSettingsOutletsGoThroughInjection() {
        let recorder = URLRecorder()
        let vm = makeVM(openExternal: { recorder.record($0) })
        vm.openWiFiSettings()
        vm.openBatterySettings()
        vm.openRemediation(checkID: "firewall")
        vm.openRemediation(checkID: "unknown-check")
        #expect(recorder.urls.map(\.absoluteString) == [
            PanelDeepLink.wifiSettingsURLString,
            PanelDeepLink.batterySettingsURLString,
            PanelDeepLink.networkSettingsURLString,  // unknown 项无深链，不开任何东西
        ])
    }
}

// MARK: - 窗口类用例（CI 无 WindowServer 跳过——能力守卫而非平台白名单）

extension PanelCompleteTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func popoverShellOpensAndClosesAroundPanelContent() {
        let vm = PanelViewModel(store: makeStore())
        let controller = StatusPopoverController(viewModel: vm)
        #expect(!controller.isShown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)

        controller.open(anchorView: anchor)
        #expect(controller.isShown)
        controller.toggle(anchorView: anchor)  // toggle 收起（关闭动画依赖 run loop——泵着等落定）
        var closed = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if !controller.isShown {
                closed = true
                break
            }
        }
        #expect(closed)

        window.orderOut(nil)
    }
}
