import Combine
import Foundation

// 组合根：全部依赖在此手工装配（B1）；随任务推进逐步换入真实监控器
@MainActor
public final class AppEnvironment {
    private let store: SystemStatusStore
    private let settings: SettingsStore
    private let statusBarController: StatusBarController
    private let appIconController: AppIconController
    private var placementCancellable: AnyCancellable?
    private var localizationCancellable: AnyCancellable?
    private let chargingEffectClock = ChargingEffectClock()
    private let popoverController: StatusPopoverController
    private let settingsWindowController: SettingsWindowController
    private let onboardingWindowController: OnboardingWindowController
    public let automation: AutomationCoordinator
    private let liveServices: LiveServices?
    private var chargingCancellables: Set<AnyCancellable> = []
    // T-058（A14 审计二/三）：更新与遥测两座孤岛上岸——引擎早已全绿，缺的就是这里的 start 接线
    private let updaterController: UpdaterController
    private let telemetryScheduler: TelemetryScheduler?
    /// AppKit 侧取词快照（菜单标题等非 SwiftUI 场景）：语言切换时经订阅整体重建
    public private(set) var localization: Localization

    public init(
        store: SystemStatusStore,
        settings: SettingsStore,
        statusBarController: StatusBarController,
        appIconController: AppIconController,
        popoverController: StatusPopoverController,
        settingsWindowController: SettingsWindowController,
        onboardingWindowController: OnboardingWindowController,
        automation: AutomationCoordinator = AutomationCoordinator(),
        updaterController: UpdaterController = .shared,
        telemetryScheduler: TelemetryScheduler? = nil,
        liveServices: LiveServices? = nil
    ) {
        self.store = store
        self.settings = settings
        self.statusBarController = statusBarController
        self.appIconController = appIconController
        self.popoverController = popoverController
        self.settingsWindowController = settingsWindowController
        self.onboardingWindowController = onboardingWindowController
        self.automation = automation
        self.liveServices = liveServices
        self.updaterController = updaterController
        self.telemetryScheduler = telemetryScheduler
        self.localization = Localization(language: settings.appLanguage)
    }

    /// Dock 图标在位与否（A2·S2 reopen 判定输入）：menuBarOnly 无 Dock 图标
    public var hasDockTile: Bool {
        settings.appIconPlacement.showsDockIcon
    }

    public func start() {
        statusBarController.startObserving()
        statusBarController.configure(
            popoverToggle: { [weak self] button in
                self?.popoverController.toggle(anchorView: button)
            },
            openSettings: { [weak self] in
                self?.settingsWindowController.showWindow(nil)
            }
        )
        // 语言生效（OG-FR-191）：初始按持久化语言装配菜单，此后切换即重建。
        // 菜单栏控制器收 Localization 值而非订阅设置——UI 层不反向依赖 SettingsStore 之外的组合根状态
        statusBarController.updateLocalization(localization)
        localizationCancellable = settings.$appLanguage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] language in
                guard let self else { return }
                self.localization = Localization(language: language)
                self.statusBarController.updateLocalization(self.localization)
            }
        // 首启引导：看过就不再弹，完成即落盘
        let hasSeen = UserDefaults.standard.bool(forKey: OnboardingWindowController.defaultsKey)
        onboardingWindowController.showIfNeeded(hasSeenGuide: hasSeen)
        appIconController.start()
        chargingEffectClock.start(store: store, settings: settings)
        chargingEffectClock.$glow
            .receive(on: DispatchQueue.main)
            .sink { [weak self] glow in
                guard let self else { return }
                self.statusBarController.renderGlow(glow)
            }
            .store(in: &chargingCancellables)
        placementCancellable = settings.$appIconPlacement
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] placement in
                self?.statusBarController.setVisible(placement.showsMenuBarIcon)
            }
        store.start()
        // Sparkle（OG-FR-200）：占位域阶段内部已拦（isConfigured=false 不起更新循环），
        // 上线换真 plist 后同一路径自动全量生效
        updaterController.start()
        // 遥测（OG-FR-201）：资格三轴 + 24h 节流全在调度器内；网络采样由调度器闭包链持有
        telemetryScheduler?.start()
    }

    public func stop() {
        store.stop()
        appIconController.stop()
        liveServices?.stop()
        chargingEffectClock.stop()
        chargingCancellables.removeAll()
        placementCancellable = nil
        localizationCancellable = nil
        telemetryScheduler?.stop()
    }

    // MARK: - Dock 点击入口（applicationShouldHandleReopen 接线，A2·S2）

    /// Dock 图标点击的弹层入口。弹层（NSPopover）只能锚定视图——本 App 唯一常驻锚点是
    /// 菜单栏图标按钮（弹层控制器不支持屏幕坐标锚定），故从菜单栏锚点弹出；
    /// dockOnly 隐藏菜单栏图标时无锚可依，降级开设置
    public func togglePopoverFromStatusBar() {
        if let button = statusBarController.anchorButton {
            popoverController.toggle(anchorView: button)
        } else {
            settingsWindowController.showWindow(nil)
        }
    }

    public func showSettingsWindow() {
        settingsWindowController.showWindow(nil)
    }

    /// 调试构建标记（遥测资格轴：开发机流量不得混入生产统计，S11）
    private static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    public static func live() -> AppEnvironment {
        // 登录项真服务在此注入：SettingsStore 默认保持纯持久化（测试/CLI 宿主零副作用）
        let settings = SettingsStore(loginItem: SystemLoginItemService())
        // T-020/T-021/T-022 落地：真监控器上场，图标数据从此来自真实系统状态
        let store = SystemStatusStore(
            battery: BatteryMonitor(),
            wifi: WiFiMonitor(),
            volume: VolumeMonitor(),
            refreshInterval: .seconds(settings.refreshIntervalSeconds)
        )
        let controller = StatusBarController(
            store: store,
            settings: settings,
            localization: Localization(language: settings.appLanguage)
        )
        let appIconController = AppIconController(store: store, settings: settings)
        let automation = AutomationCoordinator()
        let services = LiveServices(settings: settings, store: store, automation: automation)
        let popover = StatusPopoverController(viewModel: services.panelViewModel)
        let settingsWindow = SettingsWindowController(settings: settings)
        // 引导完成的同一时机做遥测首次询问（OG-FR-201：默认关，明示同意才开；
        // NSAlert 模态只存在于真机运行路径——单测/CI 不构造 live()）
        let onboarding = OnboardingWindowController(
            localization: Localization(language: settings.appLanguage),
            onFinish: { [weak settings] in
                UserDefaults.standard.set(true, forKey: OnboardingWindowController.defaultsKey)
                guard let settings else { return }
                guard TelemetryFirstConsent.needsAsk(current: settings.telemetryConsent) else { return }
                settings.telemetryConsent = TelemetryFirstConsent.presentDialog(
                    localization: Localization(language: settings.appLanguage)
                )
            }
        )
        // 心跳调度（OG-FR-201）：持久层直连 UserDefaults（consent 与设置页同键）；
        // 网络轴采样对象被闭包链持有，生命周期与调度器一致
        let reachability = TelemetryReachability()
        reachability.start()
        let telemetryScheduler = TelemetryScheduler(
            store: TelemetryDefaultsStore(defaults: .standard),
            sender: TelemetrySender(),
            makeHeartbeat: {
                // @Sendable 闭包不持 SettingsStore（Swift 6 非 Sendable 捕获禁令）——
                // 图标位置直读持久化快照，与 SettingsStore 写入同键同源
                let placement = AppIconPlacement(
                    rawValue: UserDefaults.standard.string(forKey: SettingsStore.appPlacementDefaultsKey) ?? ""
                ) ?? .menuBarOnly
                return TelemetryHeartbeat.readEnvironment(
                    installationID: TelemetryPolicy.installationID(defaults: .standard),
                    placement: placement
                )
            },
            isDebugBuild: isDebugBuild,
            networkReachable: { reachability.isReachable }
        )
        return AppEnvironment(
            store: store, settings: settings,
            statusBarController: controller, appIconController: appIconController,
            popoverController: popover, settingsWindowController: settingsWindow,
            onboardingWindowController: onboarding,
            automation: automation,
            telemetryScheduler: telemetryScheduler,
            liveServices: services
        )
    }
}
