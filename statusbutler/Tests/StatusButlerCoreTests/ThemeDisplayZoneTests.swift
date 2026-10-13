import CloudKit
import Foundation
import Testing

@testable import StatusButlerCore

// T-214/219/220（C2 P2/P3 主题·显示区三件）：
// 昼夜主题切换决策 / DDC 亮度滑杆映射与调光渐变 / iCloud 开关与 entitlements 模板 /
// 趣味皮肤帧表与槽位标记。全部纯逻辑 + 注入闭包（DDC 写、CloudKit 探测均不触真 IO），
// CI 无 WindowServer 可跑；KVO/NSApp 接线属 live 面（DaylightSwitcher.start），不在测试面内。

@MainActor
@Suite struct ThemeDisplayZoneTests {
    private func makeDefaults() -> UserDefaults {
        let name = "theme-display-zone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeStore() -> StatusSnapshot {
        StatusSnapshot(
            battery: .battery(level: 66, charging: false),
            link: .wifi(ssid: "H", signalBars: 4),
            volume: VolumeState(level: 50, isMuted: false)
        )
    }

    // MARK: - T-214b 昼夜相位与切换决策

    @Test func daylightPhaseMapsAppearanceNames() {
        #expect(DaylightPhase.from(appearanceName: "NSAppearanceNameDarkAqua") == .dark)
        #expect(DaylightPhase.from(appearanceName: "NSAppearanceNameVibrantDark") == .dark)
        #expect(DaylightPhase.from(appearanceName: "NSAppearanceNameAqua") == .light)
        // 未知名（本地化/第三方外观）按亮色兜底：错切夜间主题比错切日间更扰人
        #expect(DaylightPhase.from(appearanceName: "SomeThirdPartyAppearance") == .light)
        #expect(DaylightPhase.from(appearanceName: "") == .light)
    }

    @Test func daylightThemeKeysAreValidPresetsByDefault() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(!store.autoDaylightTheme, "默认关（E23 保守口径）")
        #expect(!store.autoBrightness, "外接屏自动调光默认关")
        #expect(ThemePresets.all[store.daylightTheme] != nil, "默认日间键必须是合法预设")
        #expect(ThemePresets.all[store.dayNightTheme] != nil, "默认夜间键必须是合法预设")
        #expect(store.daylightTheme == "colorful")
        #expect(store.dayNightTheme == "darkNight")
    }

    @Test func daylightSettingsPersistRoundTrip() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.autoDaylightTheme = true
        store.daylightTheme = "minimal"
        store.dayNightTheme = "classicMac"
        store.autoBrightness = true
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.autoDaylightTheme)
        #expect(reloaded.daylightTheme == "minimal")
        #expect(reloaded.dayNightTheme == "classicMac")
        #expect(reloaded.autoBrightness)
    }

    @Test func switcherAppliesPresetPerPhase() {
        let store = SettingsStore(defaults: makeDefaults())
        store.autoDaylightTheme = true
        store.daylightTheme = "minimal"      // iconSize 16 / footer clock
        store.dayNightTheme = "darkNight"    // iconSize 18 / footer clock
        var phase: DaylightPhase = .light
        let switcher = DaylightSwitcher(settings: store, readPhase: { phase })

        switcher.evaluate()
        #expect(store.menuBarIconSize == 16, "亮 → 日间预设 minimal（16pt）")
        phase = .dark
        switcher.evaluate()
        #expect(store.menuBarIconSize == 18, "暗 → 夜间预设 darkNight（18pt）")
        #expect(DaylightSwitcher.themeID(for: .light, daylight: "a", night: "b") == "a")
        #expect(DaylightSwitcher.themeID(for: .dark, daylight: "a", night: "b") == "b")
    }

    @Test func switcherSkipsWhenOffOrPresetMissing() {
        let store = SettingsStore(defaults: makeDefaults())
        store.autoDaylightTheme = false
        var phase: DaylightPhase = .light
        let switcher = DaylightSwitcher(settings: store, readPhase: { phase })
        switcher.evaluate()
        phase = .dark
        switcher.evaluate()
        #expect(store.menuBarIconSize == 18, "开关关：外观翻转也不动设置")

        // 预设键脏值（主题生态里预设可能被删）：查不到即不切换、不崩溃
        store.autoDaylightTheme = true
        store.daylightTheme = "不存在的预设"
        store.menuBarIconSize = 20
        phase = .light
        switcher.evaluate()
        #expect(store.menuBarIconSize == 20, "预设查不到：保持原值")
    }

    @Test func switcherDedupesSamePhaseAndRearmsAfterOff() {
        let store = SettingsStore(defaults: makeDefaults())
        store.autoDaylightTheme = true
        store.daylightTheme = "minimal"
        store.dayNightTheme = "darkNight"
        var phase: DaylightPhase = .light
        let switcher = DaylightSwitcher(settings: store, readPhase: { phase })

        switcher.evaluate()
        store.footerSlotID = "volume"   // 手动改动作为"是否重放"的探针
        switcher.evaluate()             // 同相位再求值
        #expect(store.footerSlotID == "volume", "同相位不重放预设（去抖）")
        phase = .dark
        switcher.evaluate()
        #expect(store.footerSlotID == "clock", "相位翻转即重放（darkNight footer=clock）")

        // 关 → 清记忆；再开从当前相位重新裁决
        store.autoDaylightTheme = false
        switcher.evaluate()
        store.footerSlotID = "volume"
        store.autoDaylightTheme = true
        switcher.evaluate()             // 当前相位 dark，记忆已被清
        #expect(store.footerSlotID == "clock", "关再开不带旧记忆")
    }

    // MARK: - T-214c 滑杆映射与调光渐变

    @Test func ddcSliderMappingRoundsAndClamps() {
        #expect(DDCBrightnessMapping.ddcValue(fromSlider: 49.6) == 50)
        #expect(DDCBrightnessMapping.ddcValue(fromSlider: 0.4) == 0)
        #expect(DDCBrightnessMapping.ddcValue(fromSlider: -5) == 0)
        #expect(DDCBrightnessMapping.ddcValue(fromSlider: 120) == 100)
        // 读不到当前亮度回落 50 起步（绝不能显示 0 吓用户）
        #expect(DDCBrightnessMapping.sliderValue(fromDDC: nil) == 50)
        #expect(DDCBrightnessMapping.sliderValue(fromDDC: 130) == 100)
        #expect(DDCBrightnessMapping.sliderValue(fromDDC: -1) == 0)
    }

    @Test func dimmingPlanDirectWritesWithoutStartPoint() {
        #expect(DaylightBrightnessController.plan(current: nil, target: 80) == [80],
                "无起点直写终值——瞎造起点反而首步大跳")
        let ramp = DaylightBrightnessController.plan(current: 20, target: 80, steps: 5)
        #expect(ramp.count == 5)
        #expect(ramp.first == 20)
        #expect(ramp.last == 80)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
        // 复用 BrightnessRamp 出口：越界目标钳制
        #expect(DaylightBrightnessController.plan(current: 10, target: 130, steps: 3) == [10, 55, 100])
    }

    @Test func dimmingReevaluateWritesRuleValueAsRamp() async {
        let display = DDCDisplay(id: 7)
        let writes = LockedBox<[Int]>([])
        let controller = DaylightBrightnessController(
            wiring: .init(
                displays: { [display] },
                readBrightness: { _ in 20 },
                writeBrightness: { value, _ in writes.value.append(value); return true },
                stepDelayMilliseconds: 0   // 测试免等待
            ),
            hour: { 12 }
        )
        let rule = DaylightBrightnessRule(dayValue: 80, nightValue: 30, sunriseAt: 6, sunsetAt: 18)
        await controller.reevaluate(rule: rule)
        let expected = BrightnessRamp(from: 20, to: 80, steps: DaylightBrightnessController.rampSteps, stepDelayMilliseconds: 30).sequence()
        #expect(writes.value == expected, "日间小时：从当前值渐变到日值 80")

        writes.value = []
        let evening = DaylightBrightnessController(
            wiring: .init(
                displays: { [display] },
                readBrightness: { _ in nil },   // 读不到 → 直写终值
                writeBrightness: { value, _ in writes.value.append(value); return true },
                stepDelayMilliseconds: 0
            ),
            hour: { 22 }
        )
        await evening.reevaluate(rule: rule)
        #expect(writes.value == [30], "夜间小时 + 无起点：直写夜值 30")
    }

    @Test func dimmingReevaluateSilentWithoutDisplays() async {
        let writes = LockedBox<[Int]>([])
        let controller = DaylightBrightnessController(
            wiring: .init(
                displays: { [] },
                readBrightness: { _ in nil },
                writeBrightness: { value, _ in writes.value.append(value); return true },
                stepDelayMilliseconds: 0
            ),
            hour: { 12 }
        )
        await controller.reevaluate(rule: ExternalBrightnessDefaults.rule)
        #expect(writes.value.isEmpty, "无外接屏（CI/内建屏环境）：零写入静默降级")
    }

    // MARK: - T-219 iCloud 开关 / entitlements 模板 / 状态映射

    @Test func iCloudSyncTogglesOffByDefaultAndPersists() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(!store.iCloudSyncEnabled, "默认关（IC-04）")
        store.iCloudSyncEnabled = true
        #expect(SettingsStore(defaults: defaults).iCloudSyncEnabled)
        store.iCloudSyncEnabled = false
        #expect(!SettingsStore(defaults: defaults).iCloudSyncEnabled)
    }

    @Test func entitlementsTemplateExistsWithExpectedKeys() throws {
        // #filePath 回溯包根：Tests/StatusButlerCoreTests → Tests → 包根
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appending(path: "Support/StatusButler.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let containers = try #require(
            plist["com.apple.developer.icloud-container-identifiers"] as? [String]
        )
        // 容器 id 与 CloudKitStore 常量单点对齐（改名 = 换同步域）
        #expect(containers == [CloudKitStore.containerIdentifier])
        #expect(containers == ["iCloud.com.linzhongyang.statusbutler"])
        let services = try #require(plist["com.apple.developer.icloud-services"] as? [String])
        #expect(services == ["CloudKit"], "E8 范围只用 CloudKit，不开其余 icloud-services")
    }

    @Test func iCloudErrorMappingDistinguishesAccountAndEntitlement() {
        #expect(ICloudAvailability.map(CloudKitSetupError.accountUnavailable("raw 3"))
                == .accountUnavailable)
        let notEntitled = NSError(
            domain: CKErrorDomain, code: CKError.Code.missingEntitlement.rawValue
        )
        #expect(ICloudAvailability.map(notEntitled) == .entitlementMissing)
        let other = NSError(domain: NSURLErrorDomain, code: -1009)
        guard case .unavailable = ICloudAvailability.map(other) else {
            Issue.record("其他错误应落入带原因的降级态")
            return
        }
        // 每种状态都有非空文案（设置页如实展示，IC-04 不弹窗）
        for status in [ICloudSyncStatus.checking, .available, .accountUnavailable,
                       .entitlementMissing, .unavailable("网络中断")] {
            #expect(!status.message.isEmpty)
        }
    }

    @Test func iCloudProbeUsesInjectedStoreOutcome() async {
        #expect(await ICloudAvailability.probe(makeStore: {}) == .available)
        #expect(
            await ICloudAvailability.probe(
                makeStore: { throw CloudKitSetupError.accountUnavailable("raw 3") }
            ) == .accountUnavailable
        )
        // 清单文案携带容器 id 与 record type（外部配置动作的指引面）
        #expect(ICloudAvailability.checklistText.contains(CloudKitStore.containerIdentifier))
        #expect(ICloudAvailability.checklistText.contains(CloudKitStore.recordType))
    }

    // MARK: - T-220 趣味皮肤

    @Test func skinCatalogFrameTablesAreComplete() {
        #expect(AnimatedSkinCatalog.all.count == 2)
        let cat = AnimatedSkinCatalog.skin(named: AnimatedSkinCatalog.runningCatID)
        #expect(cat?.frames.count == 4, "跑猫 4 帧")
        #expect(cat?.symbol == "cat.fill")
        let fish = AnimatedSkinCatalog.skin(named: AnimatedSkinCatalog.swimmingFishID)
        #expect(fish?.frames.count == 3, "游鱼 3 帧")
        for skin in AnimatedSkinCatalog.all.values {
            #expect(!skin.frames.isEmpty)
            #expect(skin.frames.allSatisfy { !$0.isEmpty && $0 != " " })
            #expect(SkinFrame.fpsRange.contains(skin.fps))
            #expect(!skin.symbol.isEmpty)
        }
        #expect(AnimatedSkinCatalog.skin(named: nil) == nil, "未配置 = 不启用")
        #expect(AnimatedSkinCatalog.skin(named: "不存在的皮肤") == nil, "脏值静默关")
    }

    @Test func skinFrameClampsFpsAndSanitizesFrames() {
        #expect(SkinFrame(symbol: "s", frames: ["a", "b"], fps: -3).fps == 1)
        #expect(SkinFrame(symbol: "s", frames: ["a", "b"], fps: 0).fps == 1)
        #expect(SkinFrame(symbol: "s", frames: ["a", "b"], fps: 99).fps == 12)
        // 空白帧剔除；全脏帧表退化为 [symbol]，永不产出空表
        #expect(SkinFrame(symbol: "cat", frames: ["a", " ", "", "b"], fps: 4).frames == ["a", "b"])
        #expect(SkinFrame(symbol: "cat", frames: ["", "  "], fps: 4).frames == ["cat"])
    }

    @Test func skinFramePicksCyclicallyByTime() {
        let skin = SkinFrame(symbol: "s", frames: ["a", "b", "c"], fps: 2)
        #expect(skin.frame(at: 0) == "a")
        #expect(skin.frame(at: 0.49) == "a")
        #expect(skin.frame(at: 0.5) == "b")
        #expect(skin.frame(at: 1.0) == "c")
        #expect(skin.frame(at: 1.5) == "a", "环形回卷")
        #expect(skin.frame(at: -3) == "a", "时钟回拨按 0 兜底不越界")
    }

    @Test func slotScenesCarryAnimatedSkinMarkOnlyWhenInjected() {
        let snapshot = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SlotScene().animatedSkin == nil, "场景默认不启用")
        #expect(ClockSlot().scene(snapshot: snapshot, now: now)?.animatedSkin == nil)
        #expect(DiskFreeSlot(available: { 128 * 1_000_000_000 }).scene(snapshot: snapshot, now: now)?.animatedSkin == nil)
        #expect(BatteryPercentSlot().scene(snapshot: snapshot, now: now)?.animatedSkin == nil)

        let skin = AnimatedSkinCatalog.runningCat
        let clock = ClockSlot(animatedSkin: skin).scene(snapshot: snapshot, now: now)
        #expect(clock?.animatedSkin == skin)
        #expect(clock?.valueText != nil, "皮肤不顶掉文本：叠放而非替换")
        let disk = DiskFreeSlot(available: { 128 * 1_000_000_000 }, animatedSkin: skin)
            .scene(snapshot: snapshot, now: now)
        #expect(disk?.animatedSkin == skin)
        #expect(disk?.valueText == "128G")
        let battery = BatteryPercentSlot(animatedSkin: skin).scene(snapshot: snapshot, now: now)
        #expect(battery?.animatedSkin == skin)
        #expect(battery?.valueText == "66%")
    }

    @Test func animatedSkinSettingDefaultsOffAndPersists() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.animatedSkin == nil, "默认关（E24）")
        store.animatedSkin = AnimatedSkinCatalog.swimmingFishID
        #expect(SettingsStore(defaults: defaults).animatedSkin == AnimatedSkinCatalog.swimmingFishID)
        store.animatedSkin = nil
        #expect(SettingsStore(defaults: defaults).animatedSkin == nil, "清除即移除键")
    }
}
