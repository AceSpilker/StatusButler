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

    // MARK: C2 弹层区新增状态（T-203/204/205/207）

    /// 性能最近一帧（旁路轮询发布；PerfSample 相等性不含时间戳，静默期不重发布）
    @Published public private(set) var perfSample: PerfSample?
    /// CPU P/E 拓扑（provider 一次读，开机后不变）
    @Published public private(set) var cpuTopology: CpuCoreTopology?
    /// 音频输入旁路（nil = 行隐藏）
    @Published public private(set) var audioInput: AudioInputStatus?
    /// iDevice 汇总（nil 与空 devices 都走引导文案；provider 未接线整行隐藏）
    @Published public private(set) var mobileBatterySummary: MobileBatterySummary?
    /// 历史页数据（进入下钻页才读，绝不轮询——按需数据）
    @Published public private(set) var historyDaily: [DailyMetricPoint] = []
    @Published public private(set) var historyEvents: [EventRow] = []
    /// 事件类型筛选（nil = 全部）；弹层关闭复位
    @Published public private(set) var historyEventFilter: String?
    /// 最近一次 CSV 导出结果（导出按钮的诚实反馈；nil = 本次会话未导出过）
    @Published public private(set) var lastHistoryExportSucceeded: Bool?

    // MARK: C2 P2/P3 新增状态（T-211 会议条 / T-212 养护页 / T-213 插件管理 /
    // T-216 Shortcuts 钉选 / T-221 更新扫描）

    /// 会议条（nil = 无进行中会议，整条隐藏；可见期旁路轮询维持剩余时长新鲜）
    @Published public private(set) var meetingBar: MeetingBarState?
    /// 养护页数据（进入下钻页才读，按需数据）
    @Published public private(set) var careDaily: [CareDailyPoint] = []
    @Published public private(set) var careMonthly: [CareMonthlySummary] = []
    /// 插件管理页列表（进入下钻页才扫，按需数据）
    @Published public private(set) var pluginRows: [PluginRowState] = []
    /// Shortcuts 钉选名单（出现瞬间拉一次；名单是设置登记的静态表，不轮询）
    @Published public private(set) var pinnedShortcuts: [ShortcutPin] = []
    /// 更新扫描结果（用户点"检查"才发请求——能效纪律；空表 ≠ 已扫描，见 isUpdateScanning）
    @Published public private(set) var updateResults: [CaskUpdate] = []
    @Published public private(set) var updateScanSummary: String?
    @Published public private(set) var isUpdateScanning = false

    /// 旁路采样启停标志（测试与接线方可观测；不可见恒为 false）
    public var isBypassSamplingActive: Bool {
        bluetoothPollTask != nil || thermalPollTask != nil || connectionPollTask != nil
            || perfPollTask != nil || meetingPollTask != nil
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

    // MARK: C2 弹层区新增计算面

    /// 性能分区是否接线（未接线时分区占位"性能采样未接入"，不显示假零值）
    public var isPerfAvailable: Bool { perfProvider != nil }
    /// 音频输入行可见性（provider 未接线或本轮无读数都隐藏）
    public var showsAudioInputRow: Bool { audioInput != nil }
    /// iDevice 行可见性：provider 未接线整行隐藏；接线后无论有无设备都展示分区
    /// （空设备/读不到正是占位行要引导的态）
    public var showsMobileBatteryRow: Bool { mobileBatteryProvider != nil }
    /// 历史入口行可见性（读服务未接线不给入口，点了也是空页）
    public var showsHistoryEntryRow: Bool { historyReader != nil }
    /// CSV 导出是否接线（未接线按钮隐藏）
    public var isHistoryExportAvailable: Bool { historyExportClosure != nil }

    // MARK: C2 P2/P3 计算面（T-211/212/213/216/221）

    /// 会议条可见性（无进行中会议即隐藏；provider 未接线恒隐藏）
    public var showsMeetingBar: Bool { meetingBar != nil }
    /// 会议中静音动作可点（静音闭包接线且本轮有静音态读数）
    public var isMeetingMuteActionAvailable: Bool {
        meetingMuteToggler != nil && meetingBar?.isInputMuted != nil
    }
    /// 养护页入口（月度小结读服务未接线不给入口；总览行可单独降级）
    public var showsBatteryCareEntryRow: Bool { batteryCareReader != nil }
    /// 插件管理入口（列表 provider 未接线不给入口）
    public var showsPluginEntryRow: Bool { pluginListProvider != nil }
    /// Shortcuts 入口（名单 provider 未接线不给入口——钉选区与"Shortcuts…"按钮同闸）
    public var isShortcutsEntryVisible: Bool { shortcutsListProvider != nil }
    /// 更新扫描入口（本地清单与远端版本源缺一不可——单边接线点了也是空页）
    public var showsUpdateScanEntryRow: Bool { brewListProvider != nil && caskVersionFetcher != nil }
    /// 历史页最近加载条数上限（UI 列表上限；DB 全量导出走 CSV）
    public static let historyEventLimit = 200
    /// 筛选后的事件行（新在前——recentEvents 升序取尾，展示倒序）
    public var filteredHistoryEvents: [EventRow] {
        let filtered = historyEventFilter.map { target in
            historyEvents.filter { $0.kind == target }
        } ?? historyEvents
        return filtered.reversed()
    }
    /// 当前数据里出现过的类型集合（筛选 Picker 选项；升序稳定）
    public var historyEventKindOptions: [String] {
        Array(Set(historyEvents.map(\.kind))).sorted()
    }

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

    // MARK: C2 弹层区注入（T-203/204/205/207；主线接线清单见各 typealias 注记）

    private let perfProvider: PerfSampleProvider?
    private let cpuTopologyProvider: CpuTopologyProvider?
    private let audioInputProvider: AudioInputStatusProvider?
    private let mobileBatteryProvider: MobileBatterySummaryProvider?
    private let historyReader: (any HistoryReading)?
    private let historyExportClosure: HistoryExportClosure?

    // MARK: C2 P2/P3 注入（T-211/212/213/216/221；全部可选，缺省诚实降级）

    /// 会议条：主线喂 `{ MeetingBarMapping.state(from: timeline, now: Date(), isInputMuted: mute?.isInputMuted) }`
    /// （时间轴与静音态的新鲜度归主线缓存；本 VM 只在弹层可见期轮询闭包）
    private let meetingBarProvider: MeetingBarStateProvider?
    /// 会议中静音（T-041b MuteControlling 的包装：`{ try? controller.toggleMute(now: Date()) ?? nil }`）
    private let meetingMuteToggler: MeetingMuteToggler?
    /// 养护页月度小结：主线喂 HistoryDatabase（BatteryCareReading retroactive 适配已就位）
    private let batteryCareReader: (any BatteryCareReading)?
    /// 插件列表：主线喂 `{ PluginPanelMapping.rows(from: PluginDirectory.scan(root: PluginDirectory.defaultRoot())) { runner.failureCount(pluginID: $0) } }`
    private let pluginListProvider: PluginListProvider?
    /// 插件重载：主线喂 `{ runner.reset(pluginID: $0) }`（复位计数即恢复启用）
    private let pluginReloadAction: PluginReloadAction?
    /// Shortcuts 钉选名单（设置登记表；macOS 无公开枚举 API，见 ShortcutsPanelSupport 头注）
    private let shortcutsListProvider: ShortcutsListProvider?
    /// brew 本地清单原文：主线喂 `{ await BrewListRunner.readOutput() ?? "" }` 的同步缓存
    /// （BrewListRunner 是子进程往返，不做同步闭包——主线预取缓存后 provider 读缓存）
    private let brewListProvider: (@Sendable () -> String)?
    /// Homebrew 版本源：主线喂 HomebrewCaskFetcher()（三道闸在 fetcher 内，占位实现）
    private let caskVersionFetcher: (any CaskVersionFetching)?

    private var scanTask: Task<Void, Never>?
    private var batteryDetailTask: Task<Void, Never>?
    private var pendingVolumeWriteTask: Task<Void, Never>?
    private var lastVolumeWriteAt: Date?
    private var hidConfirm = HIDConfirmModel()
    private var perfPollTask: Task<Void, Never>?
    private var meetingPollTask: Task<Void, Never>?
    private var updateScanTask: Task<Void, Never>?

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
        volumeClock: (() -> Date)? = nil,
        perfProvider: PerfSampleProvider? = nil,
        cpuTopologyProvider: CpuTopologyProvider? = nil,
        audioInputProvider: AudioInputStatusProvider? = nil,
        mobileBatteryProvider: MobileBatterySummaryProvider? = nil,
        historyReader: (any HistoryReading)? = nil,
        historyExport: HistoryExportClosure? = nil,
        meetingBarProvider: MeetingBarStateProvider? = nil,
        meetingMuteToggler: MeetingMuteToggler? = nil,
        batteryCareReader: (any BatteryCareReading)? = nil,
        pluginListProvider: PluginListProvider? = nil,
        pluginReloadAction: PluginReloadAction? = nil,
        shortcutsListProvider: ShortcutsListProvider? = nil,
        brewListProvider: (@Sendable () -> String)? = nil,
        caskVersionFetcher: (any CaskVersionFetching)? = nil
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
        self.perfProvider = perfProvider
        self.cpuTopologyProvider = cpuTopologyProvider
        self.audioInputProvider = audioInputProvider
        self.mobileBatteryProvider = mobileBatteryProvider
        self.historyReader = historyReader
        self.historyExportClosure = historyExport
        self.meetingBarProvider = meetingBarProvider
        self.meetingMuteToggler = meetingMuteToggler
        self.batteryCareReader = batteryCareReader
        self.pluginListProvider = pluginListProvider
        self.pluginReloadAction = pluginReloadAction
        self.shortcutsListProvider = shortcutsListProvider
        self.brewListProvider = brewListProvider
        self.caskVersionFetcher = caskVersionFetcher
        bind()
    }

    deinit {
        // 弱引用循环本会自行退出，这里同步 cancel 让"close 即停"在 VM 生命周期尽头也成立
        bluetoothPollTask?.cancel()
        thermalPollTask?.cancel()
        connectionPollTask?.cancel()
        perfPollTask?.cancel()
        meetingPollTask?.cancel()
        scanTask?.cancel()
        batteryDetailTask?.cancel()
        pendingVolumeWriteTask?.cancel()
        updateScanTask?.cancel()
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
        // 历史筛选随导航栈复位（transient 弹层重开不该记住上次的筛选）
        historyEventFilter = nil
        // 更新扫描是用户触发的网络往返，弹层关闭即取消；已得结果保留（重开可看）
        updateScanTask?.cancel()
        updateScanTask = nil
        isUpdateScanning = false
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
        case .history:
            refreshHistory()
        case .batteryCare:
            // 总览行复用电池详情读取；月度小结走养护读协议
            refreshBatteryDetails()
            refreshBatteryCare()
        case .plugins:
            refreshPluginRows()
        case .updateScan:
            // 首次进入自动查一轮（与附近网络页同口径：打开即意图，重进不自动重查）
            if updateResults.isEmpty && updateScanTask == nil { checkForUpdates() }
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
        // C2 弹层区（T-203/204/205）：拓扑一次读；音频输入与 iDevice 是出现瞬间的
        // 快照拉取（新鲜度归 provider 侧缓存——闭包是同步契约，子进程/异步往返
        // 由主线在 provider 背后完成）
        if let cpuTopologyProvider {
            cpuTopology = cpuTopologyProvider()
        }
        if let audioInputProvider {
            audioInput = audioInputProvider()
        }
        if let mobileBatteryProvider {
            mobileBatterySummary = mobileBatteryProvider()
        }
        // T-216：钉选名单是设置登记的静态表，出现瞬间拉一次即可（不轮询）
        if let shortcutsListProvider {
            pinnedShortcuts = shortcutsListProvider()
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
        // 性能（T-203）：provider 是即时值读取（引擎总线最近一帧），粗间隔拉取即可；
        // 引擎自身的"有人看才采样"启停归主线（PerfSampleProvider 注记），此处只是读端
        if perfProvider != nil {
            perfPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self {
                        self.refreshPerfOnce()
                    }
                    guard let self, !Task.isCancelled else { return }
                    try? await Task.sleep(
                        for: self.bypassPollInterval,
                        tolerance: self.bypassPollInterval / 5
                    )
                }
            }
        }
        // 会议条（T-211）：剩余时长/入会窗口随钟点变化，provider 轻量（读缓存），
        // 与旁路轮询同节奏维持新鲜；时间轴取数归主线（MeetingBarStateProvider 注记）
        if meetingBarProvider != nil {
            meetingPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let self {
                        self.refreshMeetingBar()
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

    /// 性能旁路单次拉取（轮询循环本体；相等帧不重发布——订阅去重铁律在源头兑现）
    public func refreshPerfOnce() {
        guard let perfProvider else { return }
        let sample = perfProvider()
        if sample != perfSample {
            perfSample = sample
        }
    }

    private func stopBypassSampling() {
        bluetoothPollTask?.cancel()
        bluetoothPollTask = nil
        thermalPollTask?.cancel()
        thermalPollTask = nil
        connectionPollTask?.cancel()
        connectionPollTask = nil
        perfPollTask?.cancel()
        perfPollTask = nil
        meetingPollTask?.cancel()
        meetingPollTask = nil
    }

    // MARK: - 历史查看页（T-207：按需数据，进入页面才读一次，绝不轮询）

    /// 读取历史数据（push(.history) 自动触发；也可手动刷新）
    public func refreshHistory() {
        guard let historyReader else { return }
        historyDaily = historyReader.dailySeries()
        historyEvents = historyReader.recentEvents(limit: Self.historyEventLimit)
        // 筛选值在新数据里已不存在（如清理后）→ 归零"全部"，避免卡在空筛选
        if let filter = historyEventFilter,
           !historyEvents.contains(where: { $0.kind == filter }) {
            historyEventFilter = nil
        }
    }

    /// 事件类型筛选（nil = 全部）
    public func setHistoryEventFilter(_ kind: String?) {
        historyEventFilter = kind
    }

    /// 导出当前筛选的事件为 CSV（所见即所得）。未接线返回 false 不伪装成功；
    /// 内容复用引擎侧 HistoryCSV（转义口径单源）
    @discardableResult
    public func exportHistoryCSV() -> Bool {
        guard let historyExportClosure else { return false }
        let events = filteredHistoryEvents.map {
            HistoryEvent(id: $0.id, at: $0.at, kind: $0.kind, detail: $0.detail)
        }
        let succeeded = historyExportClosure("statusbutler-history.csv", HistoryCSV.eventsToCSV(events))
        lastHistoryExportSucceeded = succeeded
        return succeeded
    }

    // MARK: - 会议条（T-211：进行中会议条 + 一键入会 + 会议中静音）

    /// 单次拉取会议条（旁路轮询循环本体；未接线是安全 no-op）
    public func refreshMeetingBar() {
        guard let meetingBarProvider else { return }
        meetingBar = meetingBarProvider()
    }

    /// 一键入会（MTG-01）：打开注入 openExternal（NSWorkspace 拉起客户端/浏览器）
    public func joinCurrentMeeting() {
        guard let joinURL = meetingBar?.joinURL else { return }
        openExternal(joinURL)
    }

    /// 会议中静音切换（MTG-02）：经注入闭包（T-041b MuteControlling 包装）；
    /// 返回切换后静音态并立即重拉会议条（静音徽标即时回显），nil = 失败/不可用
    @discardableResult
    public func toggleMeetingMute() -> Bool? {
        guard let meetingMuteToggler else { return nil }
        let newMuted = meetingMuteToggler()
        refreshMeetingBar()
        return newMuted
    }

    // MARK: - 电池养护页（T-212：月度小结，按需数据）

    /// 读取养护页数据（push(.batteryCare) 自动触发；总览行走 refreshBatteryDetails）
    public func refreshBatteryCare() {
        guard let batteryCareReader else { return }
        careDaily = batteryCareReader.careDailySeries()
        careMonthly = BatteryCareMapping.monthlySummaries(
            daily: careDaily,
            events: batteryCareReader.allEvents()
        )
    }

    // MARK: - 插件管理页（T-213：扫描列表 + 重载复位，按需数据）

    /// 重扫插件列表（push(.plugins) 自动触发；重载后手动重扫反映新计数）
    public func refreshPluginRows() {
        guard let pluginListProvider else { return }
        pluginRows = pluginListProvider()
    }

    /// 重载 = 复位连败计数（runner.reset）+ 重扫列表；三连击停用后的唯一恢复通道
    public func reloadPlugin(_ id: String) {
        pluginReloadAction?(id)
        refreshPluginRows()
    }

    // MARK: - Shortcuts 钉选（T-216：执行深链 + 浏览入口）

    /// 执行钉选的快捷指令（Apple 文档化 run-shortcut 深链；名字构造失败即放弃）
    public func runShortcut(_ pin: ShortcutPin) {
        guard let url = ShortcutLink.runURL(name: pin.name) else { return }
        openExternal(url)
    }

    /// 打开 Shortcuts App（"Shortcuts…"按钮——macOS 无枚举 API，浏览跳本体）
    public func openShortcutsApp() {
        openExternal(ShortcutLink.appURL)
    }

    // MARK: - 更新扫描（T-221：brew 比对提示，用户触发才发网络请求）

    /// 检查更新：解析本地清单 → 逐 cask 比对远端版本（串行——几个 cask 的
    /// 顺序往返好过并发池打 API；"有人看才运行"在入口闸已兑现，这里不节流）。
    /// 防重入：扫描中再点不叠加任务
    public func checkForUpdates() {
        guard let brewListProvider, let caskVersionFetcher, updateScanTask == nil else { return }
        isUpdateScanning = true
        updateScanTask = Task { [weak self] in
            let casks = BrewListParser.parse(brewListProvider())
            var results: [CaskUpdate] = []
            for cask in casks {
                if Task.isCancelled { return }
                let latest = await caskVersionFetcher.latestVersion(token: cask.name)
                results.append(CaskComparison.compare(installed: cask, latestVersion: latest))
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.updateResults = results
            self.updateScanSummary = CaskComparison.summaryText(for: results)
            self.isUpdateScanning = false
            self.updateScanTask = nil
        }
    }

    /// 结果行"官网"出口（cask 官方页深链；纯提示不代装）
    public func openCaskHomepage(_ update: CaskUpdate) {
        guard let url = update.homepageURL else { return }
        openExternal(url)
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
