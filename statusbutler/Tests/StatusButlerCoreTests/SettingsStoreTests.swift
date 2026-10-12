import Testing
import Foundation
@testable import StatusButlerCore

// T-003: SettingsStore 默认值 / 持久化 / 范围钳制（注入独立 defaults suite）
@MainActor
@Suite struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsOnFirstLaunch() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.menuBarIconSize == 18)
        #expect(store.refreshIntervalSeconds == 15)
        #expect(store.showsBatteryPercentage == true)
    }

    @Test func writesPersist() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.menuBarIconSize = 22
        store.refreshIntervalSeconds = 30
        store.showsBatteryPercentage = false
        // 重新加载即从磁盘读回
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.menuBarIconSize == 22)
        #expect(reloaded.refreshIntervalSeconds == 30)
        #expect(reloaded.showsBatteryPercentage == false)
    }

    @Test func storedOutOfRangeValuesAreClamped() {
        let defaults = makeDefaults()
        defaults.set(99.0, forKey: "menuBarIconSize")
        defaults.set(1, forKey: "statusRefreshIntervalSeconds")
        let store = SettingsStore(defaults: defaults)
        #expect(store.menuBarIconSize == SettingsStore.iconSizeRange.upperBound)
        #expect(store.refreshIntervalSeconds == SettingsStore.refreshIntervalRange.lowerBound)
    }
}
