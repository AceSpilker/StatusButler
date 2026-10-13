import Combine
import Foundation

// 设置仓库：UserDefaults 持久化 + @Published 驱动（可注入 defaults 供测试）
@MainActor
public final class SettingsStore: ObservableObject {
    public static let iconSizeRange: ClosedRange<Double> = 16...24
    public static let refreshIntervalRange: ClosedRange<Int> = 5...60
    /// 图标位置持久化键公开只读：遥测心跳的 @Sendable 闭包直读 UserDefaults 快照、
    /// 不持本类引用（Swift 6 非 Sendable 捕获禁令）——键字面量两处共用此常量防漂移。
    /// nonisolated：字符串常量无隔离需求，@Sendable 闭包与 Key 命名空间两侧都要够得着
    public nonisolated static let appPlacementDefaultsKey = "appIconPlacement"

    private enum Key {
        static let iconSize = "menuBarIconSize"
        static let refreshIntervalSeconds = "statusRefreshIntervalSeconds"
        static let showsBatteryPercentage = "showsBatteryPercentage"
        static let placement = SettingsStore.appPlacementDefaultsKey
        static let chargingEffect = "showsChargingEffect"
        static let footerSlot = "footerSlotID"
        static let launchAtLogin = "launchAtLogin"
        static let appLanguage = "appLanguage"
        // telemetryConsent 走 TelemetryPolicy.consentKey（与调度器持久层同键互读，
        // 单点登记在 TelemetryPolicy，此处不另设键防两处漂移）
    }

    private let defaults: UserDefaults
    /// 登录项系统服务（SMAppService 协议化）：默认 nil——仓库默认保持纯持久化，
    /// live() 组合根注入真服务；测试注入假实现
    private let loginItem: (any LoginItemServicing)?

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

    @Published public var showsChargingEffect: Bool {
        didSet { defaults.set(showsChargingEffect, forKey: Key.chargingEffect) }
    }

    @Published public var footerSlotID: String {
        didSet { defaults.set(footerSlotID, forKey: Key.footerSlot) }
    }

    /// 开机自启动（A2·S2）：didSet 即注册/注销（经注入的登录项服务）；持久化的是用户偏好，
    /// 系统注册态才是事实源——初值跟随系统（用户可能在系统设置里手动移除过）
    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            loginItem?.setRegistered(launchAtLogin)
        }
    }

    /// App 语言（OG-FR-191）：三态、独立于系统语言
    @Published public var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
            languageVersion += 1
        }
    }

    /// 语言代数：Localization 是值类型、视图无法观察其"重建"——每次切换 +1 作为刷新信号，
    /// 视图读 settings.localization 的同时观察本值即可随语言重算文案
    @Published public private(set) var languageVersion = 0

    /// 当前取词器快照（UI 行文案直取；按 appLanguage 现算，成本是两框小字典的构造）
    public var localization: Localization {
        Localization(language: appLanguage)
    }

    /// 遥测同意三态（OG-FR-201 默认关）：与 TelemetryDefaultsStore 同键（TelemetryPolicy.consentKey），
    /// 设置页写、调度器读，一处改两处见
    @Published public var telemetryConsent: TelemetryConsent {
        didSet { defaults.set(telemetryConsent.rawValue, forKey: TelemetryPolicy.consentKey) }
    }

    public init(
        defaults: UserDefaults = .standard,
        loginItem: (any LoginItemServicing)? = nil
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
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
        if defaults.object(forKey: Key.chargingEffect) == nil {
            defaults.set(true, forKey: Key.chargingEffect)
        }
        showsChargingEffect = defaults.bool(forKey: Key.chargingEffect)
        footerSlotID = defaults.string(forKey: Key.footerSlot) ?? "volume"
        if let service = loginItem, service.isSupported {
            // 系统注册态优先于存储偏好：手动移除过的登录项不该显示为"开"
            launchAtLogin = service.status.isOn
        } else {
            launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
        telemetryConsent = TelemetryConsent(rawValue: defaults.string(forKey: TelemetryPolicy.consentKey) ?? "") ?? .notAsked
    }

    // MARK: - 登录项透传（GeneralPane 开关与"待批准"提示行消费；无服务时恒未注册）

    public var loginItemStatus: LaunchAtLoginStatus {
        loginItem?.status ?? .notRegistered
    }

    public var isLoginItemSupported: Bool {
        loginItem?.isSupported ?? false
    }

    public func openLoginItemsSettings() {
        loginItem?.openSystemSettings()
    }
}
