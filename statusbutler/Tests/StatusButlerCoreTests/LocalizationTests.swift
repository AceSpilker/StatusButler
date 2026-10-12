import Testing
import Foundation
@testable import StatusButlerCore

// T-032: 双语字典 parity / resolved 语言解析 / 引导窗口与示例场景
// parity 是 A2·S10 OG-FR-191"本地化键一致性测试"的可执行化：两表漂移即红
@MainActor
@Suite struct LocalizationTests {

    // MARK: - 字典 parity

    @Test func zhHansTableMatchesAllKeys() {
        #expect(Localization.zhHans.count == LocalizationKey.allCases.count)
        #expect(Set(Localization.zhHans.keys) == Set(LocalizationKey.allCases))
    }

    @Test func englishTableMatchesAllKeys() {
        #expect(Localization.english.count == LocalizationKey.allCases.count)
        #expect(Set(Localization.english.keys) == Set(LocalizationKey.allCases))
    }

    @Test func everyKeyHasNonEmptyDistinctValuesInBothLanguages() {
        for key in LocalizationKey.allCases {
            let zh = Localization.zhHans[key] ?? ""
            let en = Localization.english[key] ?? ""
            #expect(!zh.isEmpty, "zh-Hans 缺值：\(key.rawValue)")
            #expect(!en.isEmpty, "en 缺值：\(key.rawValue)")
            #expect(zh != en, "两语言同值（疑似漏译）：\(key.rawValue)")
        }
    }

    @Test func firstBatchKeyFloor() {
        #expect(LocalizationKey.allCases.count >= 24)
    }

    // MARK: - resolved 语言解析

    @Test func systemLanguageFollowsChinesePreference() {
        let loc = Localization(language: .system, preferredLanguages: ["zh-Hans", "en-US"])
        #expect(loc.resolved() == .zhHans)
        #expect(loc.string(.panelBattery) == Localization.zhHans[.panelBattery])
    }

    @Test func systemLanguageFollowsEnglishPreference() {
        let loc = Localization(language: .system, preferredLanguages: ["en-US", "ja-JP"])
        #expect(loc.resolved() == .english)
        #expect(loc.string(.panelBattery) == Localization.english[.panelBattery])
    }

    @Test func chineseVariantsLikeZhHantResolveToZhHans() {
        #expect(Localization(language: .system, preferredLanguages: ["zh-Hant-TW"]).resolved() == .zhHans)
    }

    @Test func systemFallsBackToEnglishWhenNoChinese() {
        #expect(Localization(language: .system, preferredLanguages: ["fr-FR"]).resolved() == .english)
        #expect(Localization(language: .system, preferredLanguages: []).resolved() == .english)
    }

    @Test func explicitChoiceOverridesSystemPreference() {
        #expect(Localization(language: .zhHans, preferredLanguages: ["en-US"]).resolved() == .zhHans)
        #expect(Localization(language: .english, preferredLanguages: ["zh-Hans"]).resolved() == .english)
    }

    // MARK: - 取词

    @Test func stringReturnsTableValuePerLanguage() {
        let zh = Localization(language: .zhHans, preferredLanguages: [])
        let en = Localization(language: .english, preferredLanguages: [])
        #expect(zh.string(.menuQuit) == Localization.zhHans[.menuQuit])
        #expect(en.string(.menuQuit) == Localization.english[.menuQuit])
        #expect(zh.string(.onboardingDone) != en.string(.onboardingDone))
    }

    @Test func localizedHelpersReturnTableValues() {
        let loc = Localization(language: .zhHans, preferredLanguages: [])
        // 非 SwiftUI 场景的 String 直取（AppKit 菜单等）
        #expect(String.localized(.menuQuit, in: loc) == Localization.zhHans[.menuQuit])
    }

    @Test func appLanguageCasesAndCodableRoundTrip() throws {
        #expect(AppLanguage.allCases.count == 3)
        #expect(AppLanguage(rawValue: "system") == .system)
        #expect(AppLanguage(rawValue: "zhHans") == .zhHans)
        #expect(AppLanguage(rawValue: "english") == .english)
        // 设置持久化走 Codable 编码 rawValue，往返必须无损
        let data = try JSONEncoder().encode(AppLanguage.zhHans)
        #expect(try JSONDecoder().decode(AppLanguage.self, from: data) == .zhHans)
        #expect(AppLanguage.system.titleKey == .languageSystem)
        #expect(AppLanguage.zhHans.titleKey == .languageZhHans)
        #expect(AppLanguage.english.titleKey == .languageEnglish)
    }

    // MARK: - 引导窗口（OG-FR-190：只自动弹一次，可重开）

    @Test func showIfNeededSkipsWhenGuideAlreadySeen() {
        let controller = OnboardingWindowController()
        #expect(controller.showIfNeeded(hasSeenGuide: true) == false)
        #expect(controller.window == nil)
    }

    @Test func showIfNeededShowsOnFirstLaunch() {
        let controller = OnboardingWindowController()
        #expect(controller.showIfNeeded(hasSeenGuide: false) == true)
        #expect(controller.window != nil)
    }

    @Test func showReopensSameWindow() {
        let controller = OnboardingWindowController()
        controller.show()
        let first = controller.window
        #expect(first != nil)
        // 重开走同一窗口前置而非新建
        controller.show()
        #expect(controller.window === first)
    }

    @Test func completeClosesWindowAndNotifiesIntegrator() {
        var finished = false
        let controller = OnboardingWindowController(onFinish: { finished = true })
        controller.show()
        #expect(controller.window != nil)
        controller.complete()
        #expect(controller.window == nil)
        #expect(finished)
    }

    // MARK: - 引导固定示例场景

    @Test func sampleScenesAreWellFormed() {
        #expect(OnboardingSampleScenes.battery.batteryLevel == 78)
        #expect(OnboardingSampleScenes.battery.isCharging)
        #expect(OnboardingSampleScenes.network.signalBars == 3)
        #expect(OnboardingSampleScenes.volume.volumeDots == 2)
        for scene in [
            OnboardingSampleScenes.battery,
            OnboardingSampleScenes.network,
            OnboardingSampleScenes.volume,
        ] {
            #expect((0...4).contains(scene.signalBars))
            #expect((0...4).contains(scene.volumeDots))
        }
    }

    @Test func samplePagesFollowTopMiddleBottomOrder() {
        #expect(OnboardingSampleScenes.pages.count == 3)
        #expect(
            OnboardingSampleScenes.pages.map(\.caption)
                == [.onboardingIconTop, .onboardingIconMiddle, .onboardingIconBottom]
        )
    }

    @Test func sampleIconsRenderOffscreen() {
        // 引导示意图依赖渲染器可离屏出图（headless 确定性）
        for page in OnboardingSampleScenes.pages {
            let image = StatusIconRenderer.image(scene: page.scene, pointSize: 96, dark: false)
            #expect(image.tiffRepresentation != nil)
        }
    }
}
