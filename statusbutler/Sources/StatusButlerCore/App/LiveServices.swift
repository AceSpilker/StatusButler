import AppKit
import Combine
import Foundation

/// A14 终集成：全部"孤岛引擎"的统一挂线层。
/// live() 造一次，start()/stop() 与 AppEnvironment 同生命周期；
/// 每条注释对应审计项编号（docs/a14-audit.html）。
@MainActor
public final class LiveServices {
    public let panelViewModel: PanelViewModel
    private let settings: SettingsStore
    private let automation: AutomationCoordinator
    private let perf = PerfEngine.shared
    private let weatherFeed: WeatherFeed
    private let widgetFeed: WidgetFeedCoordinator
    private let historyFeed: HistoryFeed
    private var cancellables: Set<AnyCancellable> = []
    private var popoverVisible = false

    /// 弹层打开时才刷新的三个"按需盒"（provider 闭包同步读缓存）
    private let weatherText = LockedBox<String?>(nil)
    private let calendarText = LockedBox<String?>(nil)
    private let healthReport = LockedBox<HealthReport?>(nil)

    /// 槽位轮换的稳定顺序（设置 Picker 同源顺序 + 插件追加）
    nonisolated static let slotOrder = [
        "volume", "clock", "batteryPercent", "diskFree",
        "netSpeed", "cpuUsage", "memoryPressure", "temperature",
        "weather", "calendarCountdown",
    ]
    private static let perfSlots: Set<String> = ["netSpeed", "cpuUsage", "memoryPressure"]

    public init(settings: SettingsStore, store: SystemStatusStore, automation: AutomationCoordinator) {
        self.settings = settings
        self.automation = automation

        // γ：天气 30 分钟节拍（无城市配置时 tick 短路——诚实静默）
        weatherFeed = WeatherFeed()
        // γ：小组件快照写入者（审计最痛点）
        widgetFeed = WidgetFeedCoordinator(
            store: store,
            thermal: ThermalMonitor(),
            writer: WidgetSnapshotWriter()
        )
        // γ：历史事件落盘（容量详情留 nil——绝不写占位行）
        historyFeed = HistoryFeed(store: store)

        // β：弹层全量注入
        panelViewModel = PanelViewModel(
            store: store,
            connectionDetails: NetworkConnectionMonitor(),
            wifiScanner: SystemWiFiScanner(),
            interfaceAddresses: SystemInterfaceAddressReader(),
            batteryDetails: IORegistryBatteryReader(),
            volumeWriter: AppleScriptVolumeWriter(),
            naturalScrolling: settings.naturalVolumeScrolling,
            bluetoothOperator: IOBluetoothOperator(),
            bluetoothBattery: SystemBluetoothBatterySource(),
            actions: ActionRegistry.builtin,
            actionExecutor: { [weak automation] action in
                automation?.performAction(action) ?? .rejected(reason: "automation 未就绪")
            },
            weatherProvider: { [weatherText] in weatherText.value },
            calendarProvider: { [calendarText] in calendarText.value },
            healthReportProvider: { [healthReport] in healthReport.value },
            slotCycler: SettingsSlotCycler(settings: settings),
            openExternal: { NSWorkspace.shared.open($0) }
        )
    }

    public func start(popover: StatusPopoverController) {
        weatherFeed.start()
        widgetFeed.start()
        historyFeed.start()
        let perf = perf

        // 组件网速腿需要持续帧：暂按"组件特性启用"常开（T-059 随组件开关设置收紧）
        Task { await perf.start("widget") }

        // 弹层可见性 → 性能采样"popover"引用 + 三个按需盒刷新（有人看才运行）
        popover.onVisibilityChange = { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.popoverVisible = visible
                if visible {
                    Task { await self.perf.start("popover") }
                    Task { await self.refreshOnDemandBoxes() }
                } else {
                    Task { await self.perf.stop("popover") }
                }
            }
        }

        // 槽位选中性能源 → "slot:X" 引用
        settings.$footerSlotID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self else { return }
                Task {
                    for slot in Self.perfSlots { await self.perf.stop("slot:\(slot)") }
                    if Self.perfSlots.contains(id) { await self.perf.start("slot:\(id)") }
                }
            }
            .store(in: &cancellables)

        // ε：App Shortcuts 执行器注册（动作表同源 butler://）
        let automation = self.automation
        Task {
            await SharedIntentExecutor.shared.register { command in
                automation.performCommand(command)
            }
        }

        // ε：E8 云同步（默认关；开启且容器可用才装配——LWW 用 pack 时刻，
        // 完整逐键时间戳登记 T-059 提升保真）
        if settings.iCloudSyncEnabled {
            let settingsRef = settings
            Task {
                guard let cloud = try? await CloudKitStore.makeValidated() else { return }
                let coordinator = SyncCoordinator(
                    store: cloud,
                    localSnapshot: {
                        CloudSettingsRecord(
                            settingsJSON: Self.packedSettingsJSON(settingsRef),
                            themeJSON: ThemeCodec.encode(ThemeApplier.snapshot(from: settingsRef)),
                            modified: Date(),
                            deviceName: Host.current().localizedName ?? "Mac"
                        )
                    },
                    applyRemote: { record in
                        Self.applySettingsJSON(record.settingsJSON, to: settingsRef)
                        if let theme = try? ThemeCodec.decode(record.themeJSON) {
                            ThemeApplier.apply(theme, to: settingsRef)
                        }
                    }
                )
                _ = await coordinator.syncNow()
            }
        }
    }

    public func stop() {
        weatherFeed.stop()
        widgetFeed.stop()
        historyFeed.stop()
        cancellables.removeAll()  // 订阅断开即数据源静默；perf 引用计数随进程退出回收
    }

    private func refreshOnDemandBoxes() async {
        // 天气：直接读共享缓存（WeatherFeed 的节拍负责新鲜度）
        if let now = WeatherBus.cache.lastKnown() {
            let ( _, label) = WeatherNow.symbolism(code: now.weatherCode)
            weatherText.value = "\(label) \(Int(now.temperatureC.rounded()))°"
        }
        // 日程：24h 窗口取下一事件倒计时（CAL-03：永不携带标题）
        if let events = try? await LiveEventStore().upcomingEvents(window: 24 * 3600) {
            let timeline = EventTimeline(events: events)
            if let next = timeline.nextEvent(now: Date()) {
                calendarText.value = EventTimeline.countdownText(next: next, now: Date())
            }
        }
        // 体检：四检查并发
        let auditor = HealthAuditor(checks: [
            FileVaultCheck(), GatekeeperCheck(), FirewallCheck(), SoftwareUpdateCheck(),
        ])
        healthReport.value = await auditor.runAll()
    }

    // MARK: - 设置快照打包/回放（E8）

    private static let syncKeys = [
        "menuBarIconSize", "statusRefreshIntervalSeconds", "showsBatteryPercentage",
        "showsChargingEffect", "footerSlotID", "naturalVolumeScrolling",
        "appLanguage", "launchAtLogin",
    ]

    private static func packedSettingsJSON(_ settings: SettingsStore) -> Data {
        let raw = UserDefaults.standard
        let dict = syncKeys.compactMap { key -> (String, Any)? in
            raw.object(forKey: key).map { (key, $0) }
        }
        return (try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: dict))) ?? Data()
    }

    private static func applySettingsJSON(_ data: Data, to settings: SettingsStore) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let raw = UserDefaults.standard
        for (key, value) in dict where syncKeys.contains(key) {
            raw.set(value, forKey: key)
        }
        // 回读触发 @Published 刷新（设置页下一帧生效）
        settings.menuBarIconSize = raw.double(forKey: "menuBarIconSize")
        settings.refreshIntervalSeconds = raw.integer(forKey: "statusRefreshIntervalSeconds")
    }
}

/// 线程安全值盒（provider 闭包 @Sendable 同步读）
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// 槽位轮换（β 的 SlotCycling → 设置持久化）
/// 调用路径全部在主线程（弹层 footer 点击）；协议非隔离，故 assumeIsolated 桥接
final class SettingsSlotCycler: SlotCycling {
    private let settings: SettingsStore
    public init(settings: SettingsStore) { self.settings = settings }

    private var order: [String] {
        LiveServices.slotOrder + SlotRegistry.builtin.keys.filter { $0.hasPrefix("plugin:") }
    }

    func currentLabel() -> String {
        MainActor.assumeIsolated {
            SlotRegistry.builtin[settings.footerSlotID] != nil ? settings.footerSlotID : "volume"
        }
    }

    @discardableResult
    func cycle() -> String {
        MainActor.assumeIsolated {
            let ids = order
            guard let index = ids.firstIndex(of: settings.footerSlotID), ids.indices.contains(index + 1) else {
                settings.footerSlotID = ids.first ?? "volume"
                return self.currentLabel()
            }
            settings.footerSlotID = ids[index + 1]
            return self.currentLabel()
        }
    }
}
