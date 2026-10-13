import AppKit
import Combine
import Foundation

// MARK: - 温度域旁路读取协议（T-030）

/// 面板温度旁路的可注入抽象（沿用 `-ing` 后缀惯例）。
/// ThermalMonitor 是 struct 且无协议（T-025 只做读路径），本文件不改它、
/// 仅作同模块 retroactive 包装，让面板/测试能注入假实现
public protocol ThermalMonitoring: Sendable {
    func read() async -> ThermalSnapshot?
}

extension ThermalMonitor: ThermalMonitoring {}

// MARK: - 可见性守门人（S3 能效纪律）

/// 弹层可见性状态的唯一载体（S3"有人看才运行"的闸门）。
/// 可见性有两个来源——NSPopover 委托回调（壳层）与 SwiftUI onAppear/onDisappear（内容层），
/// 双方都汇入 setVisible；下游订阅 removeDuplicates 去重，重复上报不会重启采样链。
/// 由本类而非 NSPopover 持有状态，是为了让 PanelViewModel 不依赖 AppKit 也可单测启停
@MainActor
public final class PopoverVisibilityTracker: ObservableObject {
    @Published public private(set) var isVisible: Bool = false

    public init() {}

    public func setVisible(_ visible: Bool) {
        isVisible = visible
    }
}

// MARK: - 面板视图模型（T-030 + A14-β 弹层全量）

/// 弹层面板 VM。数据分两类，采样纪律不同（A2·S3）：
/// - 快照数据（电池/网络/音量）：SystemStatusStore 常驻轮询本来就为菜单栏图标而跑，
///   VM 只订阅其 $snapshot，经 500ms 防抖合并后落到 displaySnapshot 驱动面板重绘；
/// - 旁路数据（蓝牙/温度/连接详情）：只服务面板、绝不做进图标渲染键（架构铁律 3），
///   只在弹层可见期间采样——出现瞬间各读一次 + 粗间隔轮询，消失即 cancel；
/// - 按需数据（附近网络扫描/电池详情/体检报告）：用户打开对应下钻页才触发一次，
///   绝不轮询（能效铁律：有人看才运行，且"看"的是那一页）。
/// A14-β 起全部系统落点协议注入（主线接线清单见各 init 参数）；未注入时对应能力诚实降级。
@MainActor
public final class PanelViewModel: ObservableObject {
    /// S3 规格：打开时数据 500ms 防抖合并（窗口内多次变更只下发末值一次）
    public static let snapshotDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(500)
    /// 旁路轮询默认粗间隔：蓝牙/温度/连接详情都是毫秒级轻读，5s 对面板观感足够；
    /// 睡眠 tolerance = 间隔/5（B1：不要求 CPU 精确唤醒）
    public static let defaultBypassPollInterval: Duration = .seconds(5)
    /// 音量写节流默认窗口：滚轮/拖杆事件洪流下 ~8 次/秒的 AppleScript 是可听感与开销的平衡点
    public static let defaultVolumeWriteMinInterval: TimeInterval = 0.12

    @Published public private(set) var layout: PanelLayout
    /// 防抖后的快照（面板唯一的数据出口——不直接绑 store.$snapshot，防抖才有意义）
    @Published public private(set) var displaySnapshot: StatusSnapshot
    @Published public private(set) var bluetoothDevices: [BluetoothDeviceInfo] = []
    @Published public private(set) var thermal: ThermalSnapshot?
    @Published public private(set) var popoverVisible: Bool = false

    // MARK: A14-β 新增状态

    /// 弹层内导航栈（后进先出；空 = 概览根页）
    @Published public private(set) var routes: [PanelRoute] = []
    @Published public private(set) var connectionDetails: ConnectionDetails?
    @Published public private(set) var nearbyNetworks: [NearbyNetwork] = []
    @Published public private(set) var isScanningNearby = false
    @Published public private(set) var linkAddresses: [InterfaceAddressInfo] = []
    @Published public private(set) var batteryDetail: BatteryDetails?
    /// 音量乐观值（写出去的档位）；快照追平或弹层关闭时清除
    @Published public private(set) var volumeOverride: Int?
    /// 蓝牙"设备+电量"行（两源合并产物；无合并源时由设备清单降级合成，电量列全 nil）
    @Published public private(set) var bluetoothBatteryRows: [BluetoothDeviceWithBattery] = []
    /// HID 断开二次确认当前武装的设备地址（nil = 无待确认）
    @Published public private(set) var hidArmedAddress: String?
    @Published public private(set) var lastBluetoothOperation: BluetoothOperationResult?
    @Published public private(set) var weatherText: String?
    @Published public private(set) var calendarText: String?
    @Published public private(set) var healthReport: HealthReport?
    @Published public private(set) var slotLabel: String?
    @Published public private(set) var lastActionOutcome: ActionOutcome?

    /// 旁路采样启停标志（测试与接线方可观测；不可见恒为 false）
    public var isBypassSamplingActive: Bool {
        bluetoothPollTask != nil || thermalPollTask != nil || connectionPollTask != nil
    }

    /// 实际要渲染的分区：order ∩ visibleSections，保持 order 的排列
    public var sectionsToRender: [PanelSectionID] {
        layout.order.filter { layout.visibleSections.contains($0) }
    }

    /// 当前下钻页（nil = 概览根页）
    public var currentRoute: PanelRoute? { routes.last }

    public var isVolumeWritable: Bool { volumeWriter != nil }
    /// 音量行的显示值：乐观值优先（写路径开启时即时反馈），否则用防抖快照
    public var volumeDisplay: VolumeState {
        VolumeDisplay.resolve(snapshot: displaySnapshot.volume, override: volumeOverride)
    }
    public var currentVolumeLevel: Int {
        volumeOverride ?? displaySnapshot.volume.level
    }
    /// 天气/日程行：两个 provider 都无数据即整行隐藏（A8·WX/CAL）
    public var showsInfoStrip: Bool { weatherText != nil || calendarText != nil }
    public var showsHealthRow: Bool { healthReportProvider != nil }
    /// 动作行可执行（执行器已接线；未接线灰显而不是伪装可点）
    public var isActionCenterArmed: Bool { actionExecutor != nil }
    /// 附近网络扫描服务是否已接线（未接线时下钻页给"未接入"占位而非空列表）
    public var isScannerAvailable: Bool { wifiScanner != nil }

    private let store: SystemStatusStore
    private let bluetooth: any BluetoothMonitoring
    private let thermalMonitor: any ThermalMonitoring
    private let visibilityTracker: PopoverVisibilityTracker
    private let bypassPollInterval: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var bluetoothPollTask: Task<Void, Never>?
    private var thermalPollTask: Task<Void, Never>?
    private var connectionPollTask: Task<Void, Never>?

    // MARK: A14-β 注入（全部可选，缺省诚实降级——主线接线见各属性注释）

    private let connectionDetailsProvider: (any ConnectionDetailsProviding)?
    private let wifiScanner: (any WiFiScanning)?
    private let interfaceAddressReader: (any InterfaceAddressReading)?
    private let batteryDetailsReader: (any BatteryDetailsReading)?
    private let volumeWriter: (any VolumeWriting)?
    private let volumeWriteMinInterval: TimeInterval
    private let naturalScrolling: Bool
    private let bluetoothOperator: (any BluetoothOperating)?
    private let bluetoothBatterySource: (any BluetoothBatteryMerging)?
    private let actionsValue: [ButlerAction]
    private let actionExecutor: (@Sendable (ButlerAction) -> ActionOutcome)?
    private let weatherProvider: WeatherTextProvider?
    private let calendarProvider: CalendarTextProvider?
    private let healthReportProvider: HealthReportProvider?
    private let slotCycler: (any SlotCycling)?
    private let openExternal: @MainActor (URL) -> Void
    private let volumeClock: () -> Date

    private var scanTask: Task<Void, Never>?
    private var batteryDetailTask: Task<Void, Never>?
    private var pendingVolumeWriteTask: Task<Void, Never>?
    private var lastVolumeWriteAt: Date?
    private var hidConfirm = HIDConfirmModel()

    /// 动作中心面板行数据（注入的表原样透出；空表 = 顶部动作行隐藏）
    public var actions: [ButlerAction] { actionsValue }

    public init(
        store: SystemStatusStore,
        bluetooth: any BluetoothMonitoring = BluetoothMonitor(),
        thermal: any ThermalMonitoring = ThermalMonitor(),
        visibilityTracker: PopoverVisibilityTracker = PopoverVisibilityTracker(),
        layout: PanelLayout = .default,
        bypassPollInterval: Duration = PanelViewModel.defaultBypassPollInterval,
        connectionDetails: (any ConnectionDetailsProviding)? = nil,
        wifiScanner: (any WiFiScanning)? = nil,
        interfaceAddresses: (any InterfaceAddressReading)? = nil,
        batteryDetails: (any BatteryDetailsReading)? = nil,
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
        openExternal: (@MainActor (URL) -> Void)? = nil,
        volumeClock: (() -> Date)? = nil
    ) {
        self.store = store
        self.bluetooth = bluetooth
        self.thermalMonitor = thermal
        self.visibilityTracker = visibilityTracker
        // 非法布局（旧数据缺新分区 id 等）不整体丢弃，净化后收用
        self.layout = layout.isValid ? layout : layout.sanitized()
        self.bypassPollInterval = bypassPollInterval
        self.displaySnapshot = store.snapshot
        self.popoverVisible = visibilityTracker.isVisible
        self.connectionDetailsProvider = connectionDetails
        self.wifiScanner = wifiScanner
        self.interfaceAddressReader = interfaceAddresses
        self.batteryDetailsReader = batteryDetails
        self.volumeWriter = volumeWriter
        self.volumeWriteMinInterval = volumeWriteMinInterval
        self.naturalScrolling = naturalScrolling
        self.bluetoothOperator = bluetoothOperator
        self.bluetoothBatterySource = bluetoothBattery
        self.actionsValue = actions
        self.actionExecutor = actionExecutor
        self.weatherProvider = weatherProvider
        self.calendarProvider = calendarProvider
        self.healthReportProvider = healthReportProvider
        self.slotCycler = slotCycler
        self.openExternal = openExternal ?? { PanelViewModel.defaultOpenExternal($0) }
        self.volumeClock = volumeClock ?? { Date() }
        bind()
    }

    deinit {
        // 弱引用循环本会自行退出，这里同步 cancel 让"close 即停"在 VM 生命周期尽头也成立
        bluetoothPollTask?.cancel()
        thermalPollTask?.cancel()
        connectionPollTask?.cancel()
        scanTask?.cancel()
        batteryDetailTask?.cancel()
        pendingVolumeWriteTask?.cancel()
    }

    // MARK: - 生命周期钩子（SwiftUI onAppear/onDisappear 接这里）

    /// 弹层内容出现：开启旁路采样（读一次 + 粗间隔轮询）+ 拉一次旁路 provider
    public func panelDidAppear() {
        visibilityTracker.setVisible(true)
        refreshInfoProviders()
        if let slotCycler {
            slotLabel = slotCycler.currentLabel()
        }
    }

    /// 弹层内容消失：cancel 全部旁路采样；导航栈清零（transient 弹层重开应回到概览根页，
    /// 不该替用户记住上次的下钻位置）、乐观音量值与 HID 武装态一并复位
    public func panelWillDisappear() {
        visibilityTracker.setVisible(false)
        routes.removeAll()
        scanTask?.cancel()
        scanTask = nil
        isScanningNearby = false
        batteryDetailTask?.cancel()
        batteryDetailTask = nil
        volumeOverride = nil
        hidConfirm.reset()
        hidArmedAddress = nil
    }

    /// 更新分区布局（设置页显隐勾选/拖动排序接入用）；非法布局原样拒绝，不半途应用
    public func apply(layout newLayout: PanelLayout) {
        guard newLayout.isValid else { return }
        layout = newLayout
    }

    // MARK: - 导航栈（下钻三页 + 体检页）

    public func push(_ route: PanelRoute) {
        routes.append(route)
        switch route {
        case .nearbyNetworks:
            // 首次进入自动扫一轮（用户打开页面即表达意图），重进不自动重扫（能效）
            if nearbyNetworks.isEmpty { scanNearbyNetworks() }
        case .linkDetails:
            refreshLinkDetails()
        case .batteryDetails:
            refreshBatteryDetails()
        case .healthReport:
            refreshHealthReport()
        }
    }

    public func pop() {
        guard !routes.isEmpty else { return }
        routes.removeLast()
    }

    public func popToRoot() {
        routes.removeAll()
    }

    // MARK: - 附近网络扫描

    public func scanNearbyNetworks() {
        // 防重入：扫描阻塞数秒，扫描中按钮再点不叠加任务
        guard let wifiScanner, scanTask == nil else { return }
        isScanningNearby = true
        scanTask = Task { [weak self] in
            let networks = await wifiScanner.scan()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.nearbyNetworks = NearbyNetworkOrder.ordered(networks)
            self.isScanningNearby = false
            self.scanTask = nil
        }
    }

    /// 点击网络行 → 跳系统 Wi-Fi 设置（红线一：连接/输密码归系统，App 不碰钥匙串）
    public func openWiFiSettings() {
        openExternal(PanelDeepLink.wifiSettings)
    }

    // MARK: - 链路详情

    public func refreshLinkDetails() {
        if let connectionDetailsProvider {
            Task { [weak self] in
                let details = await connectionDetailsProvider.read()
                guard !Task.isCancelled else { return }
                self?.connectionDetails = details
            }
        }
        guard let interfaceAddressReader else { return }
        Task { [weak self] in
            let addresses = await interfaceAddressReader.read()
            guard !Task.isCancelled else { return }
            self?.linkAddresses = addresses
        }
    }

    // MARK: - 电池详情

    public func refreshBatteryDetails() {
        guard let batteryDetailsReader else { return }
        batteryDetailTask?.cancel()
        batteryDetailTask = Task { [weak self] in
            let details = await batteryDetailsReader.read()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.batteryDetail = details
            self.batteryDetailTask = nil
        }
    }

    /// 跳系统电池设置（优化充电入口在系统设置内——App 无公开 API 改它，深链是唯一诚实通道）
    public func openBatterySettings() {
        openExternal(PanelDeepLink.batterySettings)
    }

    // MARK: - 音量写路径

    /// 滑杆/滚轮统一入口：钳制 → 乐观显示 → 节流写（洪流只保留首值+尾随末值）
    public func setVolume(_ level: Int) {
        guard volumeWriter != nil else { return }  // 未接线保持只读（诚实降级，不假装写入成功）
        let clamped = VolumeScript.clamp(level)
        volumeOverride = clamped

        let decision = VolumeThrottle.decide(
            lastWriteAt: lastVolumeWriteAt,
            now: volumeClock(),
            minInterval: volumeWriteMinInterval
        )
        if decision.writeNow {
            lastVolumeWriteAt = volumeClock()
            pendingVolumeWriteTask?.cancel()
            emitVolumeWrite(clamped)
        } else if let delay = decision.flushAfter {
            pendingVolumeWriteTask?.cancel()
            pendingVolumeWriteTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(delay, 0.01)))
                guard !Task.isCancelled, let self else { return }
                guard let pending = self.volumeOverride else { return }
                self.emitVolumeWrite(pending)
                self.lastVolumeWriteAt = self.volumeClock()
            }
        }
    }

    /// 音量行内滚轮：方向经自然滚动决策表，档位钳制后走统一写入口
    public func scrollVolume(deltaY: Double) {
        guard volumeWriter != nil else { return }
        let delta = ScrollVolumeMapping.volumeDelta(
            scrollDeltaY: deltaY, naturalScrolling: naturalScrolling
        )
        setVolume(ScrollVolumeMapping.apply(delta: delta, toLevel: currentVolumeLevel))
    }

    private func emitVolumeWrite(_ level: Int) {
        guard let volumeWriter else { return }
        Task { await volumeWriter.write(level: level) }
    }

    // MARK: - 蓝牙操作

    /// 设备行点击：连接直达；断开只有 HID 类走二次确认（A2·S7——耳机/音箱误触重连代价低）
    public func toggleBluetoothDevice(_ info: BluetoothDeviceInfo) {
        guard let bluetoothOperator else { return }
        if info.isConnected && HIDConfirmModel.isHIDKind(info.kind) {
            let execute = hidConfirm.tapDisconnect(address: info.address, now: volumeClock())
            hidArmedAddress = hidConfirm.armedAddress
            guard execute else { return }
        }
        let target = !info.isConnected
        Task { [weak self] in
            let succeeded = await bluetoothOperator.setConnected(target, address: info.address)
            guard let self else { return }
            self.lastBluetoothOperation = BluetoothOperationResult(
                address: info.address, connected: target, succeeded: succeeded
            )
            // 操作后立即刷一次清单（不等下一个轮询周期，用户要看到状态变化）
            await self.refreshBluetoothOnce()
        }
    }

    /// 单次蓝牙旁路读取（轮询循环与操作后即时刷新共用）
    public func refreshBluetoothOnce() async {
        let devices: [BluetoothDeviceInfo]
        let rows: [BluetoothDeviceWithBattery]
        if let bluetoothBatterySource {
            rows = await bluetoothBatterySource.read()
            devices = rows.map(\.info)
        } else {
            devices = await bluetooth.read()
            // 无电量源降级：电量列全 nil，行结构保持一致（视图只认 nil 隐藏电量徽标）
            rows = devices.map { BluetoothDeviceWithBattery(info: $0, batteryPercent: nil) }
        }
        bluetoothDevices = devices
        bluetoothBatteryRows = rows
        // 武装中的设备已离场 → 失效待确认态（防止对失联地址误执行）
        if let armed = hidConfirm.armedAddress, !devices.contains(where: { $0.address == armed }) {
            hidConfirm.invalidate(address: armed)
            hidArmedAddress = hidConfirm.armedAddress
        }
    }

    // MARK: - 动作中心

    /// 执行面板动作（AC-02：裁决权在注入的执行器；未接线/本机不支持 → nil 且不伪装成功）
    @discardableResult
    public func perform(_ action: ButlerAction) -> ActionOutcome? {
        guard let actionExecutor, !ActionStripStyling.isDisabled(for: action.availability) else {
            return nil
        }
        let outcome = actionExecutor(action)
        lastActionOutcome = outcome
        return outcome
    }

    // MARK: - 天气/日程/体检（provider 拉取）

    private func refreshInfoProviders() {
        if let weatherProvider {
            weatherText = weatherProvider()
        }
        if let calendarProvider {
            calendarText = calendarProvider()
        }
    }

    public func refreshHealthReport() {
        guard let healthReportProvider else { return }
        healthReport = healthReportProvider()
    }

    /// 体检"去修复"：检查项 id → 系统设置深链（未知项返回 nil 时按钮不出现）
    public func openRemediation(checkID: String) {
        if let url = PanelDeepLink.remediationURL(forCheckID: checkID) {
            openExternal(url)
        }
    }

    // MARK: - 槽位轮换（footer）

    public func cycleSlot() {
        guard let slotCycler else { return }
        slotLabel = slotCycler.cycle()
    }

    // MARK: - 绑定

    private func bind() {
        // 快照防抖管道（S3"打开时数据 500ms 防抖合并"）：
        // store 每轮轮询都 willSet 一次 snapshot，直接订阅会让面板跟着每轮重绘；
        // removeDuplicates 先滤掉相等快照（能效铁律：订阅去重），
        // debounce 再把 500ms 静默窗口内的多次变更合并成末值一次下发——
        // 打开瞬间各域集中刷新时面板只重绘一次
        store.$snapshot
            .removeDuplicates()
            .debounce(for: Self.snapshotDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.displaySnapshot = snapshot
                // 乐观音量值被真实采样追平即清除；追不上则保持到弹层关闭（写已生效，显示不回跳）
                if let override = self.volumeOverride, snapshot.volume.level == override {
                    self.volumeOverride = nil
                }
            }
            .store(in: &cancellables)

        // 可见性 → 旁路启停（S3 能效纪律唯一闸门；removeDuplicates 吸收双通道重复上报）
        visibilityTracker.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.popoverVisible = visible
                if visible {
                    self?.startBypassSampling()
                } else {
                    self?.stopBypassSampling()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 旁路采样（可见期间才存在）

    private func startBypassSampling() {
        // 防重入：先撤旧链再起新链，重复的"出现"上报不会叠加轮询
        stopBypassSampling()
        bluetoothPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.refreshBluetoothOnce()
                }
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(
                    for: self.bypassPollInterval,
                    tolerance: self.bypassPollInterval / 5
                )
            }
        }
        thermalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.thermal = await self.thermalMonitor.read()
                }
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(
                    for: self.bypassPollInterval,
                    tolerance: self.bypassPollInterval / 5
                )
            }
        }
        // 连接详情（VPN/受限徽标 + 链路页数据）：注入才轮询，否则徽标保持未点亮占位
        if connectionDetailsProvider != nil {
            connectionPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, let provider = self.connectionDetailsProvider {
                        self.connectionDetails = await provider.read()
                    }
                    guard let self, !Task.isCancelled else { return }
                    try? await Task.sleep(
                        for: self.bypassPollInterval,
                        tolerance: self.bypassPollInterval / 5
                    )
                }
            }
        }
    }

    private func stopBypassSampling() {
        bluetoothPollTask?.cancel()
        bluetoothPollTask = nil
        thermalPollTask?.cancel()
        thermalPollTask = nil
        connectionPollTask?.cancel()
        connectionPollTask = nil
    }
}

// MARK: - 蓝牙操作结果（值类型，测试与 UI 可观测）

public struct BluetoothOperationResult: Equatable, Sendable {
    public let address: String
    /// 请求的目标连接态
    public let connected: Bool
    public let succeeded: Bool

    public init(address: String, connected: Bool, succeeded: Bool) {
        self.address = address
        self.connected = connected
        self.succeeded = succeeded
    }
}

// MARK: - 深链默认出口

/// NSWorkspace.open 是主线程 AppKit 调用；测试注入假闭包断言"打开过哪个 URL"
private extension PanelViewModel {
    @MainActor
    static func defaultOpenExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
