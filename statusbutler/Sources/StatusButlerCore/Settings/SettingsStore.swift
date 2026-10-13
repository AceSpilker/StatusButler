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
        static let naturalScrolling = "naturalVolumeScrolling"
        static let iCloudSync = "iCloudSyncEnabled"
        static let weatherCityName = "weatherCityName"
        static let hotKeyAssignments = "hotKeyAssignments"
        static let panelLayout = "panelLayout"
        static let autoDaylightTheme = "autoDaylightTheme"
        static let daylightTheme = "daylightTheme"
        static let dayNightTheme = "dayNightTheme"
        static let autoBrightness = "autoBrightness"
        static let animatedSkin = "animatedSkin"
        // telemetryConsent 走 TelemetryPolicy.consentKey（与调度器持久层同键互读，
        // 单点登记在 TelemetryPolicy，此处不另设键防两处漂移）
    }

    /// HotKeyCombo（Display 层）保持非 Codable 的既有事实不动：持久化在此私有 DTO 上做桥。
    /// 字段语义与 HotKeyCombo.keyCode/.modifiers 一一对应（UInt32 位掩码原样落盘）
    private struct StoredHotKeyCombo: Codable {
        let keyCode: UInt32
        let modifiers: UInt32

        init(combo: HotKeyCombo) {
            keyCode = combo.keyCode
            modifiers = combo.modifiers
        }

        var combo: HotKeyCombo {
            HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
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


    /// 弹层音量滚轮自然方向（A2·S3，β 面板消费）
    @Published public var naturalVolumeScrolling: Bool {
        didSet { defaults.set(naturalVolumeScrolling, forKey: Key.naturalScrolling) }
    }

    /// iCloud 设置同步总开关（E8，默认关）
    @Published public var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSync) }
    }

    /// 昼夜主题自动切换总开关（T-214 / E23，默认关）：开 = 跟随系统明暗外观
    /// 在 daylight/dayNight 两套预设间切（DaylightSwitcher 消费；日出日落口径见其头注释）
    @Published public var autoDaylightTheme: Bool {
        didSet { defaults.set(autoDaylightTheme, forKey: Key.autoDaylightTheme) }
    }

    /// 昼间主题预设键（T-214）：值必须是 ThemePresets.all 的键；脏值（主题包导入后被删的
    /// 预设名等）在 DaylightSwitcher 侧按"查不到预设即不切换"静默兜底，此处不做白名单校验
    @Published public var daylightTheme: String {
        didSet { defaults.set(daylightTheme, forKey: Key.daylightTheme) }
    }

    /// 夜间主题预设键（T-214）：同 daylightTheme 的兜底口径
    @Published public var dayNightTheme: String {
        didSet { defaults.set(dayNightTheme, forKey: Key.dayNightTheme) }
    }

    /// 外接屏昼夜自动调光（T-214 / E14 DDC-03，默认关）：开 = 外观变化触发
    /// DaylightBrightnessRule 求值 → 渐变写入（面板侧 DaylightBrightnessController 消费）
    @Published public var autoBrightness: Bool {
        didSet { defaults.set(autoBrightness, forKey: Key.autoBrightness) }
    }

    /// 趣味动画皮肤（T-220 / E24，默认 nil = 关）：值为 AnimatedSkinCatalog 的皮肤 id
    /// （runningCat / swimmingFish）。渲染接线见 StatusIconRenderer 侧 TODO
    @Published public var animatedSkin: String? {
        didSet {
            if let animatedSkin {
                defaults.set(animatedSkin, forKey: Key.animatedSkin)
            } else {
                defaults.removeObject(forKey: Key.animatedSkin)
            }
        }
    }

    /// 天气城市（T-201 / A8·WX-01 默认手动城市）：存城市中文名（WeatherCityCatalog.name 即键）。
    /// nil = 未配置 → WeatherFeed location 闭包返回 nil → 采样短路、天气静默（不报错不取数）。
    /// 城市表后续版本删名后查不到坐标同样静默，无需在此预校验
    @Published public var weatherCity: String? {
        didSet {
            if let weatherCity {
                defaults.set(weatherCity, forKey: Key.weatherCityName)
            } else {
                defaults.removeObject(forKey: Key.weatherCityName)
            }
        }
    }

    /// 全局热键键位表（T-206 / E22）：actionID（对齐 ActionRegistry 的 id）→ 组合键。
    /// 空 = 全部未设置（热键功能整体静默）。持久化经 StoredHotKeyCombo DTO 编码为 JSON
    @Published public var hotKeyAssignments: [String: HotKeyCombo] {
        didSet {
            let stored = Dictionary(
                uniqueKeysWithValues: hotKeyAssignments.map { ($0.key, StoredHotKeyCombo(combo: $0.value)) })
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Key.hotKeyAssignments)
            }
        }
    }

    /// 弹层分区布局（T-209 / A2·S3）：显隐 + 排序，唯一状态源在设置层（架构铁律）。
    /// 读回时 sanitized 兜底（旧数据缺新分区 id / 重复项收敛回合法排列），
    /// UI 写入路径经 PanelLayoutEditor 纯函数，天然合法
    @Published public var panelLayout: PanelLayout {
        didSet {
            if let data = try? JSONEncoder().encode(panelLayout) {
                defaults.set(data, forKey: Key.panelLayout)
            }
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
        if defaults.object(forKey: Key.naturalScrolling) == nil {
            defaults.set(true, forKey: Key.naturalScrolling)
        }
        naturalVolumeScrolling = defaults.bool(forKey: Key.naturalScrolling)
        if defaults.object(forKey: Key.iCloudSync) == nil {
            defaults.set(false, forKey: Key.iCloudSync)
        }
        iCloudSyncEnabled = defaults.bool(forKey: Key.iCloudSync)
        if let service = loginItem, service.isSupported {
            // 系统注册态优先于存储偏好：手动移除过的登录项不该显示为"开"
            launchAtLogin = service.status.isOn
        } else {
            launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
        // T-214/E23：昼夜主题三键。bool 默认关；预设键默认昼 colorful / 夜 darkNight
        //（ThemePresets.all 内建键，启动即合法）。脏值兜底在消费侧（见属性注释）
        if defaults.object(forKey: Key.autoDaylightTheme) == nil {
            defaults.set(false, forKey: Key.autoDaylightTheme)
        }
        autoDaylightTheme = defaults.bool(forKey: Key.autoDaylightTheme)
        daylightTheme = defaults.string(forKey: Key.daylightTheme) ?? "colorful"
        dayNightTheme = defaults.string(forKey: Key.dayNightTheme) ?? "darkNight"
        // T-214/E14：外接屏昼夜自动调光，默认关（隐私/能效保守口径与 E8/E24 一致）
        if defaults.object(forKey: Key.autoBrightness) == nil {
            defaults.set(false, forKey: Key.autoBrightness)
        }
        autoBrightness = defaults.bool(forKey: Key.autoBrightness)
        // T-220/E24：趣味皮肤默认关（nil），非法皮肤 id 同样在消费侧按"查不到=不启用"兜底
        animatedSkin = defaults.string(forKey: Key.animatedSkin)
        telemetryConsent = TelemetryConsent(rawValue: defaults.string(forKey: TelemetryPolicy.consentKey) ?? "") ?? .notAsked
        weatherCity = defaults.string(forKey: Key.weatherCityName)
        if let data = defaults.data(forKey: Key.hotKeyAssignments),
           let stored = try? JSONDecoder().decode([String: StoredHotKeyCombo].self, from: data) {
            hotKeyAssignments = stored.mapValues(\.combo)
        } else {
            hotKeyAssignments = [:]
        }
        if let data = defaults.data(forKey: Key.panelLayout),
           let layout = try? JSONDecoder().decode(PanelLayout.self, from: data) {
            // 损坏输入（重复/缺新分区 id）收敛回合法布局，不整体丢弃用户排序
            panelLayout = layout.sanitized()
        } else {
            panelLayout = .default
        }
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
