import Foundation

// 组合根：全部依赖在此手工装配（B1）；随任务推进逐步换入真实监控器
@MainActor
public final class AppEnvironment {
    private let store: SystemStatusStore
    private let settings: SettingsStore

    public init(store: SystemStatusStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    public func start() {
        store.start()
    }

    public func stop() {
        store.stop()
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
        return AppEnvironment(store: store, settings: settings)
    }
}
