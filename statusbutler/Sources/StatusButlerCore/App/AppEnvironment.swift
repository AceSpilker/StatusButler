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
    private let chargingEffectClock = ChargingEffectClock()
    private let popoverController: StatusPopoverController
    private let settingsWindowController: SettingsWindowController
    private let onboardingWindowController: OnboardingWindowController
    public let automation: AutomationCoordinator
    private var chargingCancellables: Set<AnyCancellable> = []

    public init(
        store: SystemStatusStore,
        settings: SettingsStore,
        statusBarController: StatusBarController,
        appIconController: AppIconController,
        popoverController: StatusPopoverController,
        settingsWindowController: SettingsWindowController,
        onboardingWindowController: OnboardingWindowController,
        automation: AutomationCoordinator = AutomationCoordinator()
    ) {
        self.store = store
        self.settings = settings
        self.statusBarController = statusBarController
        self.appIconController = appIconController
        self.popoverController = popoverController
        self.settingsWindowController = settingsWindowController
        self.onboardingWindowController = onboardingWindowController
        self.automation = automation
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
    }

    public func stop() {
        store.stop()
        appIconController.stop()
        chargingEffectClock.stop()
        chargingCancellables.removeAll()
        placementCancellable = nil
    }

    public static func live() -> AppEnvironment {
        let settings = SettingsStore()
        // T-020/T-021/T-022 落地：真监控器上场，图标数据从此来自真实系统状态
        let store = SystemStatusStore(
            battery: BatteryMonitor(),
            wifi: WiFiMonitor(),
            volume: VolumeMonitor(),
            refreshInterval: .seconds(settings.refreshIntervalSeconds)
        )
        let controller = StatusBarController(store: store, settings: settings)
        let appIconController = AppIconController(store: store, settings: settings)
        let popover = StatusPopoverController(viewModel: PanelViewModel(store: store))
        let settingsWindow = SettingsWindowController(settings: settings)
        let onboarding = OnboardingWindowController(
            localization: Localization(language: .system),
            onFinish: {
                UserDefaults.standard.set(true, forKey: OnboardingWindowController.defaultsKey)
            }
        )
        return AppEnvironment(
            store: store, settings: settings,
            statusBarController: controller, appIconController: appIconController,
            popoverController: popover, settingsWindowController: settingsWindow,
            onboardingWindowController: onboarding
        )
    }
}
