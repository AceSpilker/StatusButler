import Combine
import Foundation

// 设置仓库：UserDefaults 持久化 + @Published 驱动（可注入 defaults 供测试）
@MainActor
public final class SettingsStore: ObservableObject {
    public static let iconSizeRange: ClosedRange<Double> = 16...24
    public static let refreshIntervalRange: ClosedRange<Int> = 5...60

    private enum Key {
        static let iconSize = "menuBarIconSize"
        static let refreshIntervalSeconds = "statusRefreshIntervalSeconds"
        static let showsBatteryPercentage = "showsBatteryPercentage"
        static let placement = "appIconPlacement"
    }

    private let defaults: UserDefaults

    @Published public var menuBarIconSize: Double {
        didSet { defaults.set(menuBarIconSize, forKey: Key.iconSize) }
    }

    @Published public var refreshIntervalSeconds: Int {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Key.refreshIntervalSeconds) }
    }

    @Published public var showsBatteryPercentage: Bool {
        didSet { defaults.set(showsBatteryPercentage, forKey: Key.showsBatteryPercentage) }
    }

    @Published public var appIconPlacement: AppIconPlacement {
        didSet { defaults.set(appIconPlacement.rawValue, forKey: Key.placement) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSize = defaults.double(forKey: Key.iconSize)
        menuBarIconSize = storedSize == 0 ? 18 : min(max(storedSize, Self.iconSizeRange.lowerBound), Self.iconSizeRange.upperBound)
        let storedInterval = defaults.integer(forKey: Key.refreshIntervalSeconds)
        refreshIntervalSeconds = storedInterval == 0 ? 15 : min(max(storedInterval, Self.refreshIntervalRange.lowerBound), Self.refreshIntervalRange.upperBound)
        if defaults.object(forKey: Key.showsBatteryPercentage) == nil {
            defaults.set(true, forKey: Key.showsBatteryPercentage)
        }
        showsBatteryPercentage = defaults.bool(forKey: Key.showsBatteryPercentage)
        let raw = defaults.string(forKey: Key.placement)
        appIconPlacement = AppIconPlacement(rawValue: raw ?? "") ?? .menuBarOnly
    }
}
