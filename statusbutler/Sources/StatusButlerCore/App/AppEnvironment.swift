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
    private var chargingCancellables: Set<AnyCancellable> = []

    public init(
        store: SystemStatusStore,
        settings: SettingsStore,
        statusBarController: StatusBarController,
        appIconController: AppIconController
    ) {
        self.store = store
        self.settings = settings
        self.statusBarController = statusBarController
        self.appIconController = appIconController
    }

    public func start() {
        statusBarController.startObserving()
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
        // T-020+ 将替换为 IOKit/CoreWLAN/CoreAudio 真实现
        let settings = SettingsStore()
        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.unavailable),
            wifi: StaticWiFiMonitor(.offline),
            volume: StaticVolumeMonitor(VolumeState(level: 0, isMuted: false)),
            refreshInterval: .seconds(settings.refreshIntervalSeconds)
        )
        let controller = StatusBarController(store: store, settings: settings)
        let appIconController = AppIconController(store: store, settings: settings)
        return AppEnvironment(
            store: store, settings: settings,
            statusBarController: controller, appIconController: appIconController
        )
    }
}
