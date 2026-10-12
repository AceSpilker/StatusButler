import AppKit
import Combine

// 充电呼吸时钟（A2·S1）：发布当前 glow；睡眠/唤醒与充电状态门控
@MainActor
public final class ChargingEffectClock: ObservableObject {
    @Published public private(set) var glow: Double?
    private var settings: SettingsStore?
    private var store: SystemStatusStore?
    private var timer: Timer?
    private var startedAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var displayAsleep = false

    public init() {}

    public func start(store: SystemStatusStore, settings: SettingsStore) {
        guard timer == nil else { return }
        self.store = store
        self.settings = settings
        startedAt = Date()

        let center = NSWorkspace.shared.notificationCenter
        displayAsleep = false
        cancellables.removeAll()
        center.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.displayAsleep = true }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.displayAsleep = false }
            .store(in: &cancellables)

        // 20fps 足够菜单栏呼吸光效（能效纪律：仅充电时真正跑）
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        glow = nil
    }

    private func tick() {
        guard let store, let settings, let startedAt else { return }
        let isCharging: Bool
        if case .battery(_, let charging) = store.snapshot.battery { isCharging = charging } else { isCharging = false }
        let policy = ChargingEffectPolicy(
            enabled: settings.showsChargingEffect,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            displayAsleep: displayAsleep,
            isCharging: isCharging
        )
        guard policy.isActive else {
            glow = nil
            return
        }
        glow = ChargingEffectPhase.glow(elapsed: .seconds(-startedAt.timeIntervalSinceNow))
    }
}
