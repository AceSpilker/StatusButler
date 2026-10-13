import Testing
import Foundation
import AppKit
@testable import StatusButlerCore

// T-058（A14 审计三 / S11）：语言三态持久化与菜单文案重建 / consent 三态持久化（设置页与
// 调度器同键互读）/ 首次询问判定 / 更新手动检查的拦截裁决。

// MARK: - App 语言（OG-FR-191）

@MainActor
@Suite struct AppLanguageSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func appLanguagePersistsAcrossReloadInAllThreeStates() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.appLanguage == .system)

        store.appLanguage = .english
        #expect(SettingsStore(defaults: defaults).appLanguage == .english)
        store.appLanguage = .zhHans
        #expect(SettingsStore(defaults: defaults).appLanguage == .zhHans)
        store.appLanguage = .system
        #expect(SettingsStore(defaults: defaults).appLanguage == .system)
    }

    @Test func languageVersionBumpsOnEverySwitch() {
        let store = SettingsStore(defaults: makeDefaults())
        let before = store.languageVersion
        store.appLanguage = .zhHans
        #expect(store.languageVersion == before + 1)
        store.appLanguage = .english
        #expect(store.languageVersion == before + 2)
    }

    @Test func localizationSnapshotFollowsStoredLanguage() {
        let store = SettingsStore(defaults: makeDefaults())
        store.appLanguage = .zhHans
        #expect(store.localization.resolved() == .zhHans)
        store.appLanguage = .english
        #expect(store.localization.resolved() == .english)
        // system 态保留待解析（preferredLanguages 决定），不预先坍缩
        store.appLanguage = .system
        #expect(store.localization.language == .system)
    }

    @Test func dirtyLanguageValueFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("klingon", forKey: "appLanguage")
        #expect(SettingsStore(defaults: defaults).appLanguage == .system)
    }
}

// MARK: - 菜单文案本地化（StatusBarController 菜单三标题）

@MainActor
@Suite struct StatusBarMenuLocalizationTests {
    private func titles(of menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test func menuTitlesComeFromLocalizationTable() {
        let version = "9.9.9"
        let zh = StatusBarController.makeMenu(
            localization: Localization(language: .zhHans, preferredLanguages: []),
            version: version
        )
        let en = StatusBarController.makeMenu(
            localization: Localization(language: .english, preferredLanguages: []),
            version: version
        )
        #expect(titles(of: zh) == ["状态管家 v9.9.9", "设置…", "退出状态管家"])
        #expect(titles(of: en) == ["StatusButler v9.9.9", "Settings…", "Quit StatusButler"])
        // 版本号走 %@ 格式位填充，不拼死在表里
        #expect(titles(of: zh)[0].contains(version))
        // 设置项携带 action（quit 由系统 terminate 承载；选择子比对跳过私有访问层级）
        let settingsItem = zh.items.first { $0.action == NSSelectorFromString("settingsClicked") }
        #expect(settingsItem != nil)
        #expect(zh.items.last?.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func versionItemIsDisabledPlaceholder() {
        let menu = StatusBarController.makeMenu(
            localization: Localization(language: .zhHans, preferredLanguages: []),
            version: "1.0"
        )
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func controllerRebuildsMenuWhenLanguageChanges() throws {
        // 构造真 controller 需 NSStatusBar（窗口服务宿主）——CI 跳过，本地 GUI 照常验证
        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.unavailable),
            wifi: StaticWiFiMonitor(.offline),
            volume: StaticVolumeMonitor(VolumeState(level: 0, isMuted: false))
        )
        let settings = SettingsStore(defaults: {
            let name = "test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }())
        let controller = StatusBarController(
            store: store,
            settings: settings,
            localization: Localization(language: .zhHans, preferredLanguages: [])
        )
        let zhTitles = titles(of: controller.menu)
        #expect(zhTitles.contains("退出状态管家"))

        controller.updateLocalization(Localization(language: .english, preferredLanguages: []))
        let enTitles = titles(of: controller.menu)
        #expect(enTitles.contains("Quit StatusButler"))
        #expect(!enTitles.contains("退出状态管家"))
    }
}

// MARK: - 遥测同意三态（OG-FR-201 默认关）

@MainActor
@Suite struct TelemetryConsentWiringTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func consentRoundTripsThroughSchedulerKey() {
        // 设置页写的键 = 调度器持久层读的键（TelemetryPolicy.consentKey 单点登记）——
        // 两端各自声明键的写法在这里会被立即抓出来
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.telemetryConsent == .notAsked)

        store.telemetryConsent = .optedIn
        #expect(TelemetryDefaultsStore(defaults: defaults).consent() == .optedIn)
        store.telemetryConsent = .optedOut
        #expect(TelemetryDefaultsStore(defaults: defaults).consent() == .optedOut)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.telemetryConsent == .optedOut)
    }

    @Test func dirtyConsentValueFallsBackToNotAsked() {
        let defaults = makeDefaults()
        defaults.set("whatever", forKey: TelemetryPolicy.consentKey)
        #expect(SettingsStore(defaults: defaults).telemetryConsent == .notAsked)
        #expect(TelemetryDefaultsStore(defaults: defaults).consent() == .notAsked)
    }

    @Test func firstAskHappensOnlyWhenNotAsked() {
        #expect(TelemetryFirstConsent.needsAsk(current: .notAsked))
        #expect(!TelemetryFirstConsent.needsAsk(current: .optedIn))
        #expect(!TelemetryFirstConsent.needsAsk(current: .optedOut))
    }

    @Test func notAskedNeverQualifiesForSending() {
        // "默认关"的最终防线：三态里只有 optedIn 过发送资格（与 TelemetryPolicy 三轴对表）
        #expect(!TelemetryPolicy.shouldSend(consent: .notAsked, isDebugBuild: false, networkReachable: true))
        #expect(TelemetryPolicy.shouldSend(consent: .optedIn, isDebugBuild: false, networkReachable: true))
        #expect(!TelemetryPolicy.shouldSend(consent: .optedOut, isDebugBuild: false, networkReachable: true))
    }
}

// MARK: - 更新手动检查拦截（Sparkle 接线的 fail-safe/fail-visible 裁决）

@Suite struct UpdateCheckDecisionTests {
    @Test func proceedsOnlyWhenConfiguredAndAble() {
        #expect(UpdateCheckDecision.resolve(isConfigured: true, canCheckForUpdates: true) == .check)
    }

    @Test func blockedWhileUnconfiguredOrBusy() {
        #expect(UpdateCheckDecision.resolve(isConfigured: false, canCheckForUpdates: true) == .blocked)
        #expect(UpdateCheckDecision.resolve(isConfigured: true, canCheckForUpdates: false) == .blocked)
        #expect(UpdateCheckDecision.resolve(isConfigured: false, canCheckForUpdates: false) == .blocked)
    }

    @Test func placeholderFeedNeverEscapesTheGate() {
        // 假 Info dict：占位域（上线前 plist 的真实形态）即便配上公钥也不放行手动检查
        let placeholder = UpdaterFeedInfo.from(infoDictionary: [
            "SUFeedURL": "https://statusbutler.invalid/appcast.xml",
            "SUPublicEDKey": "MEUCIQDtest-public-key",
        ])
        #expect(!placeholder.isConfigured)
        #expect(
            UpdateCheckDecision.resolve(isConfigured: placeholder.isConfigured, canCheckForUpdates: true)
                == .blocked
        )
        // 真配置才放行
        let real = UpdaterFeedInfo.from(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": "MEUCIQDtest-public-key",
        ])
        #expect(real.isConfigured)
        #expect(
            UpdateCheckDecision.resolve(isConfigured: real.isConfigured, canCheckForUpdates: true)
                == .check
        )
    }
}
