import Foundation
import Testing
@testable import StatusButlerCore

// T-053a: 菜单栏整理引擎——规则求值/plan/diff/版本门控/会话账本纯逻辑层
// 扫描器只做 live 冒烟（headless 安全），不做环境相关断言（CI 无 GUI 返回空是契约的一部分）
@Suite struct MenubarTidyTests {
    private let dropbox = MenubarItem(ownerAppName: "Dropbox", identifier: "com.dropbox.Dropbox")
    private let zoom = MenubarItem(ownerAppName: "Zoom", identifier: "us.zoom.xos")

    // MARK: - 规则求值（全分支）

    @Test func noRulesDefaultsToVisible() {
        #expect(TidyRule.visibility(for: zoom, rules: [], batteryPercent: nil))
        #expect(TidyRule.visibility(for: zoom, rules: [], batteryPercent: 80))
    }

    @Test func alwaysHideMatchesOwnIdentifierOnly() {
        #expect(!TidyRule.visibility(for: zoom, rules: [.alwaysHide(identifier: "us.zoom.xos")], batteryPercent: 100))
        // 指向别人的规则不外溢
        #expect(TidyRule.visibility(for: zoom, rules: [.alwaysHide(identifier: "other.app")], batteryPercent: 100))
    }

    @Test func showOnlyWhenStrictlyBelowThreshold() {
        let rule = TidyRule.showOnlyWhen(appIdentifier: "us.zoom.xos", batteryBelow: 20)
        #expect(TidyRule.visibility(for: zoom, rules: [rule], batteryPercent: 19))
        #expect(!TidyRule.visibility(for: zoom, rules: [rule], batteryPercent: 20))  // 恰好阈值不算"低于"
        #expect(!TidyRule.visibility(for: zoom, rules: [rule], batteryPercent: 21))
        #expect(TidyRule.visibility(for: dropbox, rules: [rule], batteryPercent: 19))  // 只作用于目标 App
    }

    @Test func showOnlyWhenUnknownBatteryFailsVisible() {
        // 电池读不到（.unavailable → nil）按显示兜底：不因缺数据吞图标（MB-05 精神）
        let rule = TidyRule.showOnlyWhen(appIdentifier: "us.zoom.xos", batteryBelow: 20)
        #expect(TidyRule.visibility(for: zoom, rules: [rule], batteryPercent: nil))
    }

    @Test func neverTouchBehavesLikeAbsentRule() {
        #expect(TidyRule.visibility(for: zoom, rules: [.neverTouch], batteryPercent: 50))
        #expect(TidyRule.visibility(for: zoom, rules: [.neverTouch, .alwaysHide(identifier: "other.app")], batteryPercent: 50))
    }

    @Test func firstMatchingRuleWins() {
        // 排序即优先级：首条命中后，后续规则不再参与
        let hideFirst: [TidyRule] = [
            .alwaysHide(identifier: "us.zoom.xos"),
            .showOnlyWhen(appIdentifier: "us.zoom.xos", batteryBelow: 100),
        ]
        #expect(!TidyRule.visibility(for: zoom, rules: hideFirst, batteryPercent: 50))
        let showFirst = Array(hideFirst.reversed())
        #expect(TidyRule.visibility(for: zoom, rules: showFirst, batteryPercent: 50))  // 50<100 命中显示
    }

    // MARK: - 编解码

    @Test func ruleCodableRoundTrip() throws {
        let rules: [TidyRule] = [
            .alwaysHide(identifier: "us.zoom.xos"),
            .showOnlyWhen(appIdentifier: "com.dropbox.Dropbox", batteryBelow: 20),
            .neverTouch,
        ]
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([TidyRule].self, from: data) == rules)
    }

    @Test func unknownRuleTypeDecodesToNeverTouch() throws {
        // 未来格式（如 MB-02 的"按时间隐藏"）落进旧版本：不炸、不吞，回退占位
        let json = #"[{"type":"hideOnSchedule","from":"22:00"}]"#
        let decoded = try JSONDecoder().decode([TidyRule].self, from: Data(json.utf8))
        #expect(decoded == [.neverTouch])
    }

    @Test func tidySettingsRoundTripAndTolerantDecode() throws {
        let settings = TidySettings(isEnabled: true, rules: [.alwaysHide(identifier: "us.zoom.xos")])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(TidySettings.self, from: data) == settings)
        // 空 JSON 对象也解得动：老档案/手改文件不至于炸设置加载，回默认（关、无规则）
        #expect(try JSONDecoder().decode(TidySettings.self, from: Data("{}".utf8)) == TidySettings())
    }

    // MARK: - plan 与 changes

    @Test func planComputesTargetStatesIdempotently() {
        let current = [
            dropbox,
            zoom,
            MenubarItem(ownerAppName: "System", identifier: "sys.item", isVisible: false),
        ]
        let rules: [TidyRule] = [
            .alwaysHide(identifier: "us.zoom.xos"),
            .showOnlyWhen(appIdentifier: "com.dropbox.Dropbox", batteryBelow: 30),
        ]
        let target = TidyEngine.plan(current: current, rules: rules, battery: 25)
        #expect(target.map(\.identifier) == current.map(\.identifier))  // 条目不增不减，只改可见性
        #expect(target.map(\.isVisible) == [true, false, true])  // 25<30 显示；sys 无规则回默认可见（被"找回"）
        // 幂等：目标态再 plan 一次不变
        #expect(TidyEngine.plan(current: target, rules: rules, battery: 25) == target)
    }

    @Test func changesEmptyWhenAlreadyAtTarget() {
        let current = [
            MenubarItem(ownerAppName: "A", identifier: "a", isVisible: false),
            MenubarItem(ownerAppName: "B", identifier: "b", isVisible: true),
        ]
        #expect(TidyEngine.changes(current: current, target: current).isEmpty)  // 已达标 → 空变更集
    }

    @Test func changesEmitOnlyFlippedItems() {
        let current = [
            MenubarItem(ownerAppName: "A", identifier: "a", isVisible: true),
            MenubarItem(ownerAppName: "B", identifier: "b", isVisible: false),
            MenubarItem(ownerAppName: "C", identifier: "c", isVisible: true),
        ]
        let target = [
            MenubarItem(ownerAppName: "A", identifier: "a", isVisible: false),  // 需隐藏
            MenubarItem(ownerAppName: "B", identifier: "b", isVisible: false),
            MenubarItem(ownerAppName: "C", identifier: "c", isVisible: true),
        ]
        let diff = TidyEngine.changes(current: current, target: target)
        #expect(diff.count == 1)
        #expect(diff.first?.item.identifier == "a")
        #expect(diff.first?.to == false)
    }

    @Test func changesIgnoreIdentifiersMissingInCurrent() {
        // 新出现的条目不在 diff 里凭空生成动作（未知项默认不碰）
        let current = [MenubarItem(ownerAppName: "A", identifier: "a", isVisible: true)]
        let target = [
            MenubarItem(ownerAppName: "A", identifier: "a", isVisible: true),
            MenubarItem(ownerAppName: "New", identifier: "new", isVisible: false),
        ]
        #expect(TidyEngine.changes(current: current, target: target).isEmpty)
    }

    // MARK: - 电池联动 / 版本门控

    @Test func batteryPercentFromSnapshot() {
        #expect(TidyEngine.batteryPercent(from: .battery(level: 37, charging: false)) == 37)
        #expect(TidyEngine.batteryPercent(from: .battery(level: 8, charging: true)) == 8)
        #expect(TidyEngine.batteryPercent(from: .unavailable) == nil)
    }

    @Test func versionGateOnlyAdmitsVerifiedMajors() {
        #expect(VersionGate.isSupported(osMajor: 26, verified: [25, 26]))  // 白名单内放行
        #expect(!VersionGate.isSupported(osMajor: 27, verified: [25, 26]))  // 未验证拒绝
        #expect(!VersionGate.isSupported(osMajor: 26, verified: []))  // fail-closed
        #expect(VersionGate.defaultVerifiedMajors.isEmpty)  // 实机回归前一律禁用
    }

    // MARK: - 会话账本（崩溃安全）

    @Test func hiddenStateTrackerRestoreAllClears() async {
        let tracker = HiddenStateTracker()
        await tracker.recordHidden("a")
        await tracker.recordHidden("b")
        #expect(await tracker.currentlyHidden() == ["a", "b"])
        await tracker.recordRestored("a")
        #expect(await tracker.currentlyHidden() == ["b"])
        let toRestore = await tracker.restoreAll()
        #expect(toRestore == ["b"])  // 取走待恢复集合
        #expect(await tracker.currentlyHidden().isEmpty)  // 账本清零："恢复全部"路径终态
    }

    // MARK: - 执行层 stub

    @Test func nullApplierIsSafeNoop() async {
        await NullMenubarTidyApplier().apply(changes: [
            (MenubarItem(ownerAppName: "A", identifier: "a"), to: false),
        ])
    }

    // MARK: - 扫描层

    @Test func mergedItemsPreferIconLevelAndSortDeterministically() {
        let iconLevel = [
            MenubarItem(ownerAppName: "Zoom", title: "会议", identifier: "us.zoom.xos", isVisible: false),
        ]
        let appLevel = [
            MenubarItem(ownerAppName: "Dropbox", identifier: "com.dropbox.Dropbox"),
            MenubarItem(ownerAppName: "Zoom", identifier: "us.zoom.xos"),  // 同 id 的 App 级候选被图标级顶掉
        ]
        let merged = RunningAppsMenubarScanner.mergedItems(iconLevel: iconLevel, appLevel: appLevel)
        #expect(merged.map(\.identifier) == ["com.dropbox.Dropbox", "us.zoom.xos"])  // 按 App 名稳定排序
        #expect(merged.last?.title == "会议")  // 图标级的信息量保留
        #expect(merged.last?.isVisible == false)
    }

    @Test @MainActor func scannerLiveSmokeIsHeadlessSafe() {
        // live 冒烟：真机上有 GUI 会返回候选清单，headless CI 返回空——两者都算通过；
        // 非空时校验契约：标识非空可匹配、无重复
        let items = RunningAppsMenubarScanner().scan()
        let ids = items.map(\.identifier)
        #expect(ids.allSatisfy { !$0.isEmpty })
        #expect(Set(ids).count == ids.count)
    }
}
