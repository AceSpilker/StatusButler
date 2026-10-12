import Foundation

// T-032: 双语取词核心（A2·S10 OG-FR-191：首发 zh-Hans + English，App 语言可独立于系统语言）
// 纯 Swift 字典方案——不动 Package.swift 的 resources（.lproj 资源包需改包清单，留待后续任务）。
// 迁移路径已铺平：LocalizationKey.rawValue 就是将来 .lproj strings 文件里的键名，
// 迁移时只需把两张表搬进 zh-Hans.lproj/en.lproj 并把 string(_:) 换成 NSLocalizedString，
// 调用方（键、签名、测试）零改动。

/// App 语言：可独立于系统语言切换；system = 跟随 macOS 首选语言
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case zhHans
    case english

    /// 设置页语言选择器的展示文案键（语言名按各自母语书写是选择器的业界惯例）
    public var titleKey: LocalizationKey {
        switch self {
        case .system: .languageSystem
        case .zhHans: .languageZhHans
        case .english: .languageEnglish
        }
    }
}

/// 文案键：首批 ≥24 键，覆盖菜单 / 面板分区 / 设置分区 / 引导 / 状态短语骨架
/// rawValue 同时是未来 .lproj 的键名，一旦发布即冻结不可改名
public enum LocalizationKey: String, CaseIterable, Sendable {
    // 菜单栏状态菜单
    case menuQuit
    case menuVersion
    case menuSettings

    // 面板分区
    case panelBattery
    case panelNetwork
    case panelVolume
    case panelBluetooth
    case panelThermal
    case panelPerformance

    // 设置分区
    case settingsTitle
    case settingsGeneral
    case settingsAppearance
    case settingsPanel
    case settingsAbout
    case settingsLanguage

    // 语言选择器选项
    case languageSystem
    case languageZhHans
    case languageEnglish

    // 首次引导
    case onboardingTitle
    case onboardingWelcome
    case onboardingIconTop
    case onboardingIconMiddle
    case onboardingIconBottom
    case onboardingNext
    case onboardingBack
    case onboardingDone

    // 状态短语
    case batteryCharging
    case batteryLowPower
    case wifiOff
    case wifiNoInternet
    case volumeMuted
    case fanModeSystem
}

/// 取词器：值对象（非单例）。语言切换时由组合根整体重建，避免全局可变状态
public struct Localization: Sendable, Equatable {
    // 两表键集必须与 LocalizationKey.allCases 完全一致——parity 由 LocalizationTests 钉死，
    // 漏键即测试红，这是"字符串全部外置"红线的可执行化
    public static let zhHans: [LocalizationKey: String] = [
        .menuQuit: "退出状态管家",
        .menuVersion: "状态管家 v%@",  // 带 %@ 格式位，调用方 String(format:) 填版本号
        .menuSettings: "设置…",
        .panelBattery: "电池",
        .panelNetwork: "网络",
        .panelVolume: "音量",
        .panelBluetooth: "蓝牙",
        .panelThermal: "温度与风扇",
        .panelPerformance: "性能",
        .settingsTitle: "设置",
        .settingsGeneral: "通用",
        .settingsAppearance: "外观",
        .settingsPanel: "面板",
        .settingsAbout: "关于",
        .settingsLanguage: "语言",
        .languageSystem: "跟随 macOS",
        .languageZhHans: "简体中文",
        .languageEnglish: "英语",
        .onboardingTitle: "认识你的图标",
        .onboardingWelcome: "状态管家把电量、网络、音量画进一枚菜单栏小图标。翻页认识图标的三个区域。",
        .onboardingIconTop: "顶部是电池：胶囊里的填充代表电量，充电时叠一枚绿色闪电，电量过低时变红提醒。",
        .onboardingIconMiddle: "中部是网络：三段弧线加圆点代表 Wi-Fi 信号，越满越稳；全部变淡表示已断网。",
        .onboardingIconBottom: "底部是音量：四个圆点代表音量高低，静音时圆点变暗。",
        .onboardingNext: "下一页",
        .onboardingBack: "上一页",
        .onboardingDone: "开始使用",
        .batteryCharging: "正在充电",
        .batteryLowPower: "电量偏低",
        .wifiOff: "Wi-Fi 已断开",
        .wifiNoInternet: "已连接，但无法访问网络",
        .volumeMuted: "已静音",
        .fanModeSystem: "跟随系统",
    ]

    public static let english: [LocalizationKey: String] = [
        .menuQuit: "Quit StatusButler",
        .menuVersion: "StatusButler v%@",  // format placeholder for the version string
        .menuSettings: "Settings…",
        .panelBattery: "Battery",
        .panelNetwork: "Network",
        .panelVolume: "Volume",
        .panelBluetooth: "Bluetooth",
        .panelThermal: "Thermal & Fan",
        .panelPerformance: "Performance",
        .settingsTitle: "Settings",
        .settingsGeneral: "General",
        .settingsAppearance: "Appearance",
        .settingsPanel: "Panel",
        .settingsAbout: "About",
        .settingsLanguage: "Language",
        .languageSystem: "Follow macOS",
        .languageZhHans: "Simplified Chinese",
        .languageEnglish: "English",
        .onboardingTitle: "Meet Your Icon",
        .onboardingWelcome: "StatusButler draws battery, network, and volume into one tiny menu bar icon. Flip through to learn its three areas.",
        .onboardingIconTop: "Top is the battery: the capsule fill shows the level, a green bolt appears while charging, and it turns red when low.",
        .onboardingIconMiddle: "Middle is the network: three arcs and a dot show Wi-Fi signal — the fuller, the better; all dimmed means offline.",
        .onboardingIconBottom: "Bottom is the volume: four dots show how loud it is; they dim when muted.",
        .onboardingNext: "Next",
        .onboardingBack: "Back",
        .onboardingDone: "Get Started",
        .batteryCharging: "Charging",
        .batteryLowPower: "Low Battery",
        .wifiOff: "Wi-Fi Off",
        .wifiNoInternet: "Connected, No Internet",
        .volumeMuted: "Muted",
        .fanModeSystem: "System Managed",
    ]

    public let language: AppLanguage
    /// 注入而非自取：测试要喂假的首选语言列表，不依赖宿主机设置
    private let preferredLanguages: [String]

    public init(
        language: AppLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.language = language
        self.preferredLanguages = preferredLanguages
    }

    /// 解析生效语言：显式选择优先；system 时看首选语言里有无 zh 开头
    /// （zh-Hans / zh-Hant / zh-CN… 均归简体——首发只有简中表），否则英文兜底
    public func resolved() -> AppLanguage {
        switch language {
        case .zhHans, .english:
            return language
        case .system:
            return preferredLanguages.contains { $0.hasPrefix("zh") } ? .zhHans : .english
        }
    }

    /// 取词：缺键兜底回 rawValue（界面至少可读键名而不是空串；parity 测试保证正常不会命中）
    public func string(_ key: LocalizationKey) -> String {
        let table = resolved() == .zhHans ? Self.zhHans : Self.english
        return table[key] ?? key.rawValue
    }
}
