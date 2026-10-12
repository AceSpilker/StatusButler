import Testing
import Foundation
@testable import StatusButlerCore

// T-031: 设置中心框架——ThemeApplier 落地/跳过说明/往返导出、槽位持久化、分区枚举完整性
@MainActor
@Suite struct SettingsCenterTests {
    private func makeDefaults() -> UserDefaults {
        let name = "settings-center-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: ThemeApplier.apply

    @Test func applyFullThemeHitsSupportedStoreFields() {
        let store = SettingsStore(defaults: makeDefaults())
        let theme = ButlerTheme(
            appearance: ThemeAppearance(iconSize: 22, showsBatteryPercentage: false),
            sections: nil,
            footerSlotID: "clock"
        )
        _ = ThemeApplier.apply(theme, to: store)
        #expect(store.menuBarIconSize == 22)
        #expect(store.showsBatteryPercentage == false)
        #expect(store.footerSlotID == "clock")
    }

    @Test func applyNilFieldsLeaveStoreUntouched() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        // 预置成与主题 nil 字段不同的值，应用后必须原样保留（nil = 主题不覆盖此项）
        store.showsBatteryPercentage = false
        store.footerSlotID = "volume"
        let theme = ButlerTheme(appearance: ThemeAppearance(iconSize: 20))
        _ = ThemeApplier.apply(theme, to: store)
        #expect(store.showsBatteryPercentage == false)
        #expect(store.footerSlotID == "volume")
        #expect(store.menuBarIconSize == 20)
    }

    @Test func applyReportsSkipsForUnsupportedFields() {
        let store = SettingsStore(defaults: makeDefaults())
        // colorful 预设带满 6 个暂未支持的外观键 + sections 排序
        let skipped = ThemeApplier.apply(ThemePresets.all["colorful"]!, to: store)
        #expect(skipped.count == 7)
        #expect(skipped.contains("符号缩放（symbolScale）暂未支持"))
        #expect(skipped.contains("环形样式（ringStyle）暂未支持"))
        #expect(skipped.contains("低电阈值（batteryThreshold）暂未支持"))
        #expect(skipped.contains("强调色（accentHex）暂未支持"))
        #expect(skipped.contains("警示色（warningHex）暂未支持"))
        #expect(skipped.contains("充电色（chargingHex）暂未支持"))
        #expect(skipped.contains("分区排序（sections）待状态面板布局合入"))
    }

    @Test func applySkipsUnknownFooterSlotWithNote() {
        let store = SettingsStore(defaults: makeDefaults())
        let skipped = ThemeApplier.apply(
            ButlerTheme(footerSlotID: "teleport"),
            to: store
        )
        #expect(store.footerSlotID == "volume")          // 默认值未被破坏
        #expect(skipped == ["底部槽位「teleport」未注册，已跳过"])
    }

    @Test func applyClampsIconSizeIntoSupportedRange() {
        let store = SettingsStore(defaults: makeDefaults())
        _ = ThemeApplier.apply(ButlerTheme(appearance: ThemeAppearance(iconSize: 99)), to: store)
        #expect(store.menuBarIconSize == SettingsStore.iconSizeRange.upperBound)
        _ = ThemeApplier.apply(ButlerTheme(appearance: ThemeAppearance(iconSize: 1)), to: store)
        #expect(store.menuBarIconSize == SettingsStore.iconSizeRange.lowerBound)
    }

    @Test func applyAcceptsPendingSlotAsFooter() {
        // 占位源在注册表内即合法选择（待数据源 ≠ 不存在），导入主题不该丢失用户选择
        let store = SettingsStore(defaults: makeDefaults())
        let skipped = ThemeApplier.apply(ButlerTheme(footerSlotID: "netSpeed"), to: store)
        #expect(store.footerSlotID == "netSpeed")
        #expect(skipped.isEmpty)
    }

    // MARK: ThemeApplier.snapshot 往返

    @Test func snapshotRoundTripIsStable() {
        let store = SettingsStore(defaults: makeDefaults())
        store.menuBarIconSize = 23
        store.showsBatteryPercentage = false
        store.footerSlotID = "batteryPercent"
        let exported = ThemeApplier.snapshot(from: store)
        // 导出只含本机支持字段，回灌不应产生任何跳过项
        let skipped = ThemeApplier.apply(exported, to: store)
        #expect(skipped.isEmpty)
        #expect(store.menuBarIconSize == 23)
        #expect(store.showsBatteryPercentage == false)
        #expect(store.footerSlotID == "batteryPercent")
        // 再导出一次，值不变（apply(snapshot(from:)) 收敛）
        #expect(ThemeApplier.snapshot(from: store) == exported)
    }

    @Test func snapshotOnlyCarriesSupportedFields() {
        let store = SettingsStore(defaults: makeDefaults())
        let exported = ThemeApplier.snapshot(from: store)
        #expect(exported.schemaVersion == ButlerTheme.currentSchemaVersion)
        #expect(exported.appearance?.iconSize == store.menuBarIconSize)
        #expect(exported.appearance?.showsBatteryPercentage == store.showsBatteryPercentage)
        // 未支持的字段不编造数据（导出不产出假配置）
        #expect(exported.appearance?.symbolScale == nil)
        #expect(exported.appearance?.ringStyle == nil)
        #expect(exported.sections == nil)
        #expect(exported.footerSlotID == store.footerSlotID)
    }

    // MARK: 槽位选择持久化

    @Test func footerSlotSelectionPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.footerSlotID = "clock"
        // 换新实例即从 defaults 读回：设置面板写入必须能被下一次启动看到
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.footerSlotID == "clock")
    }

    // MARK: 分区枚举与槽位选项（侧栏/Picker 数据源）

    @Test func panesCoverAllSectionsWithNonEmptyTitles() {
        #expect(SettingsPane.allCases.count == 4)
        let titles = SettingsPane.allCases.map(\.title)
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty)
            #expect(!pane.symbol.isEmpty)
        }
        #expect(Set(titles).count == titles.count, "分区标题不可重名")
    }

    @Test func slotOptionsCoverRegistryAndMarkPendingSources() {
        let optionIDs = Set(SettingsSlotOptions.all.map(\.id))
        #expect(optionIDs == Set(SlotRegistry.builtin.keys), "Picker 选项必须与注册表一屏对齐")
        for option in SettingsSlotOptions.all {
            #expect(!option.title.isEmpty)
            let knownPending = ["netSpeed", "cpuUsage", "memoryPressure", "temperature", "weather"]
            #expect(option.isPending == knownPending.contains(option.id))
        }
        // 已实现源排在占位源前面，保证首次打开默认选中的音量在可视区
        let firstPending = SettingsSlotOptions.all.firstIndex(where: \.isPending)
        let lastImplemented = SettingsSlotOptions.all.lastIndex(where: { !$0.isPending })
        #expect(firstPending != nil && lastImplemented != nil)
        #expect(firstPending! > lastImplemented!)
    }
}
