import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import StatusButlerCore

// T-201/206/208/209（C2 P1 设置区四件）：城市搜索/热键录制与冲突/主题导入导出/分区布局编辑。
// 全部纯逻辑 + 注入 IO（文件面板/UserDefaults 均不触真实窗口与磁盘），
// CI 无 WindowServer 可跑；NSOpenPanel/NSSavePanel 默认闭包不在测试面内。

@MainActor
@Suite struct SettingsZoneP1Tests {
    private func makeDefaults() -> UserDefaults {
        let name = "settings-zone-p1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - T-201 城市表与搜索

    @Test func catalogHoldsFortyPlusUniqueCities() {
        #expect(WeatherCityCatalog.all.count >= 40)
        let names = WeatherCityCatalog.all.map(\.name)
        #expect(Set(names).count == names.count, "城市名是持久化键，不可重复")
        let pinyins = WeatherCityCatalog.all.map(\.pinyin)
        #expect(Set(pinyins).count == pinyins.count)
        for city in WeatherCityCatalog.all {
            #expect(city.pinyin == city.pinyin.lowercased(), "拼音统一小写，匹配侧免二次归一")
            #expect((-90.0...90.0).contains(city.latitude))
            #expect((-180.0...180.0).contains(city.longitude))
        }
        // 抽查坐标精确性（WeatherFeed 取数直接用这对值）
        let beijing = WeatherCityCatalog.city(named: "北京")
        #expect(beijing?.latitude ?? 0 == 39.9042 && beijing?.longitude ?? 0 == 116.4074)
        #expect(WeatherCityCatalog.city(named: "不存在的城市") == nil)
    }

    @Test func searchMatchesChinesePrefixAndContains() {
        // 前缀：首字命中
        #expect(WeatherCityCatalog.search("北").map(\.name).contains("北京"))
        // 包含：非首字也命中（"京" 命中 北京/南京/东京 一类）
        let jing = WeatherCityCatalog.search("京").map(\.name)
        #expect(jing.contains("北京"))
        #expect(jing.contains("南京"))
        #expect(jing.contains("东京"))
        // 全名精确
        #expect(WeatherCityCatalog.search("上海").map(\.name) == ["上海"])
        // 无命中
        #expect(WeatherCityCatalog.search("不存在的城市xyz").isEmpty)
    }

    @Test func searchMatchesPinyinCaseInsensitive() {
        // 大小写不敏感：HANG 与 hang 同结果（"hang" 同时包含命中 shanghai/changsha 等，含语义）
        let upper = WeatherCityCatalog.search("HANG").map(\.name)
        let lower = WeatherCityCatalog.search("hang").map(\.name)
        #expect(upper == lower)
        #expect(upper.contains("杭州"))
        #expect(upper.contains("上海"), "shanghai 包含 hang——包含命中是规格行为")
        // 前缀：bei 命中 beijing
        let bei = WeatherCityCatalog.search("bei").map(\.name)
        #expect(bei.contains("北京"))
        #expect(!bei.contains("上海"))
        // 拼音唯一命中（多词全拼连写）
        #expect(WeatherCityCatalog.search("hangzho").map(\.name) == ["杭州"])
        let eiji = WeatherCityCatalog.search("eiji").map(\.name)
        #expect(eiji == ["北京"], "拼音包含命中唯一")
    }

    @Test func searchEmptyQueryReturnsAllAndTrims() {
        #expect(WeatherCityCatalog.search("") == WeatherCityCatalog.all)
        #expect(WeatherCityCatalog.search("   ") == WeatherCityCatalog.all, "纯空白视同未输入")
        #expect(WeatherCityCatalog.search(" 杭州 ").map(\.name) == ["杭州"], "查询两侧空白修剪")
    }

    @Test func weatherCityPersistsAndClears() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.weatherCity == nil, "首次启动未配置 = 天气静默")
        store.weatherCity = "深圳"
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.weatherCity == "深圳")
        reloaded.weatherCity = nil
        let cleared = SettingsStore(defaults: defaults)
        #expect(cleared.weatherCity == nil, "清除后重载仍为 nil（removeObject 而非空串）")
    }

    // MARK: - T-206 热键捕获/展示/冲突/持久化

    @Test func captureMapsModifierFlagsToCarbonBits() {
        // NSEvent.ModifierFlags 可直构（无事件源），位掩码换算复用 HotKeyCombo.encodeModifiers
        let combo = HotKeyRecorder.capture(
            modifiers: NSEvent.ModifierFlags([.command, .shift]),
            keyCode: UInt16(kVK_ANSI_X)
        )
        #expect(combo == HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: HotKeyCombo.encodeModifiers(command: true, shift: true)
        ))
        let all = HotKeyRecorder.capture(
            modifiers: NSEvent.ModifierFlags([.command, .option, .shift, .control]),
            keyCode: UInt16(kVK_Space)
        )
        #expect(all?.modifiers == HotKeyCombo.encodeModifiers(command: true, option: true, shift: true, control: true))
        #expect(all?.keyCode == UInt32(kVK_Space))
    }

    @Test func captureRejectsShiftOnlyAndBareKeys() {
        // 仅 ⇧：Carbon 会全局拦截吞掉正常大写输入，拒绝注册
        #expect(HotKeyRecorder.capture(
            modifiers: NSEvent.ModifierFlags([.shift]), keyCode: UInt16(kVK_ANSI_X)
        ) == nil)
        // 无修饰键同理
        #expect(HotKeyRecorder.capture(modifiers: [], keyCode: UInt16(kVK_ANSI_X)) == nil)
        // ⇧+⌥ 合法（⌥ 满足门槛）
        #expect(HotKeyRecorder.capture(
            modifiers: NSEvent.ModifierFlags([.shift, .option]), keyCode: UInt16(kVK_ANSI_X)
        ) != nil)
    }

    @Test func displayStringUsesSystemModifierOrder() {
        // 系统偏好顺序 ⌃⌥⇧⌘ 后跟键面；与"⌘⇧X 形式"即 修饰键串+键面 的要求一致
        let cmdShiftX = HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), command: true, shift: true)
        #expect(HotKeyRecorder.displayString(for: cmdShiftX) == "⇧⌘X")
        let everything = HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_S),
            command: true, option: true, shift: true, control: true
        )
        #expect(HotKeyRecorder.displayString(for: everything) == "⌃⌥⇧⌘S")
        let bare = HotKeyCombo(keyCode: UInt32(kVK_Space), command: true)
        #expect(HotKeyRecorder.displayString(for: bare) == "⌘空格")
        // 未识别键码诚实回退数字（不空白不猜）
        let unknown = HotKeyCombo(keyCode: 999, command: true)
        #expect(HotKeyRecorder.displayString(for: unknown) == "⌘#999")
        // F 键区间直算
        let f5 = HotKeyCombo(keyCode: UInt32(kVK_F5), command: true)
        #expect(HotKeyRecorder.displayString(for: f5) == "⌘F5")
    }

    @Test func findConflictsGroupsDuplicateCombos() {
        let a = HotKeyCombo(keyCode: 7, modifiers: HotKeyCombo.encodeModifiers(command: true))
        let b = HotKeyCombo(keyCode: 8, modifiers: HotKeyCombo.encodeModifiers(command: true))
        // 无重复 → 空表
        #expect(findConflicts(["mute": a, "panel": b]) == [])
        // 两个动作同键位 → 一条冲突，actionIDs 排序确定
        let conflicts = findConflicts(["panel": a, "mute": a, "fan-max": b])
        #expect(conflicts.count == 1)
        #expect(conflicts[0].actionIDs == ["mute", "panel"])
        #expect(conflicts[0].combo == a)
        // 三动作同键位也归一组
        let triple = findConflicts(["panel": a, "mute": a, "speedtest": a])
        #expect(triple.count == 1)
        #expect(triple[0].actionIDs == ["mute", "panel", "speedtest"])
        // 空表天然无冲突
        #expect(findConflicts([:]) == [])
    }

    @Test func hotKeyAssignmentsPersistAcrossReload() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), command: true, option: true)
        store.hotKeyAssignments["mute"] = combo
        store.hotKeyAssignments["panel"] = HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: HotKeyCombo.encodeModifiers(control: true))
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.hotKeyAssignments["mute"] == combo)
        #expect(reloaded.hotKeyAssignments["panel"]?.keyCode == UInt32(kVK_ANSI_P))
        #expect(reloaded.hotKeyAssignments["panel"]?.modifiers == HotKeyCombo.encodeModifiers(control: true))
        // 清除落盘：删除键位后重载不再出现
        reloaded.hotKeyAssignments.removeValue(forKey: "mute")
        let cleared = SettingsStore(defaults: defaults)
        #expect(cleared.hotKeyAssignments["mute"] == nil)
        #expect(cleared.hotKeyAssignments["panel"] != nil)
        // 损坏数据兜底为空表（热键整体静默而非崩溃）
        let broken = makeDefaults()
        broken.set(Data("junk".utf8), forKey: "hotKeyAssignments")
        #expect(SettingsStore(defaults: broken).hotKeyAssignments.isEmpty)
    }

    @Test func hotKeyActionIDsAlignWithActionRegistry() {
        // rawValue 是注册接线（HotKeyCenter → AutomationCoordinator.performAction）的寻址键，
        // 两侧漂移会让键位静默失效——测试钉死
        for action in HotKeyActionID.allCases {
            #expect(ActionRegistry.action(id: action.rawValue) != nil, "\(action.rawValue) 不在 ActionRegistry")
            #expect(!action.title.isEmpty)
        }
        #expect(HotKeyActionID.allCases.map(\.rawValue) == ["panel", "mute", "fan-max", "speedtest"])
    }

    // MARK: - T-208 主题导入导出（注入面板，零窗口零磁盘）

    private func makePort(
        pickImport: @escaping ThemePortController.URLPicker = { URL(fileURLWithPath: "/tmp/test-import.butler-theme") },
        pickExport: @escaping ThemePortController.URLPicker = { nil },
        read: @escaping (URL) throws -> Data = { _ in Data() },
        write: @escaping (URL, Data) throws -> Void = { _, _ in }
    ) -> ThemePortController {
        ThemePortController(pickImportURL: pickImport, pickExportURL: pickExport, readData: read, writeData: write)
    }

    @Test func importFailsOnBadJSONWithType() {
        let store = SettingsStore(defaults: makeDefaults())
        let port = makePort(read: { _ in Data("这不是 JSON".utf8) })
        port.beginImport(from: store)
        #expect(port.importPhase == .failed(message: ThemeError.badJSON.description))
    }

    @Test func importFailsOnSchemaTooNewWithType() {
        let store = SettingsStore(defaults: makeDefaults())
        let future = ButlerTheme(schemaVersion: ButlerTheme.currentSchemaVersion + 1, appearance: ThemeAppearance(iconSize: 20))
        let port = makePort(read: { _ in ThemeCodec.encode(future) })
        port.beginImport(from: store)
        guard case .failed(let message) = port.importPhase else {
            Issue.record("应为分型失败，实际 \(port.importPhase)")
            return
        }
        #expect(message == ThemeError.schemaTooNew(ButlerTheme.currentSchemaVersion + 1).description)
        #expect(message.contains("高于本程序支持"), "失败文案须给出升级指引")
    }

    @Test func importFailsOnMissingVersionWithType() {
        let store = SettingsStore(defaults: makeDefaults())
        // 合法 JSON 但缺 schemaVersion：宁拒不猜（无法决定按哪个版本解释）
        let noVersion = Data(#"{"appearance":{"iconSize":20}}"#.utf8)
        let port = makePort(read: { _ in noVersion })
        port.beginImport(from: store)
        #expect(port.importPhase == .failed(message: ThemeError.missingVersion.description))
    }

    @Test func importCancelledPanelStaysIdle() {
        let store = SettingsStore(defaults: makeDefaults())
        let port = makePort(pickImport: { nil })  // 用户取消文件面板
        port.beginImport(from: store)
        #expect(port.importPhase == .idle, "取消不是失败")
        // 读文件抛错（如权限/文件消失）单列失败态
        struct Boom: Error {}
        let unreadable = makePort(read: { _ in throw Boom() })
        unreadable.beginImport(from: store)
        guard case .failed = unreadable.importPhase else {
            Issue.record("读失败应进 failed")
            return
        }
    }

    @Test func importPreviewListsOnlyIncomingFields() {
        let store = SettingsStore(defaults: makeDefaults())
        store.menuBarIconSize = 18
        store.footerSlotID = "volume"
        let theme = ButlerTheme(
            appearance: ThemeAppearance(iconSize: 22, ringStyle: .thin, showsBatteryPercentage: false),
            footerSlotID: "clock"
        )
        let port = makePort(read: { _ in ThemeCodec.encode(theme) })
        port.beginImport(from: store)
        guard case .previewing(let rows) = port.importPhase else {
            Issue.record("应进预览态，实际 \(port.importPhase)")
            return
        }
        #expect(rows.count == 4, "只列新主题携带的字段（iconSize/ringStyle/百分比/槽位），nil 不出行")
        #expect(rows.map(\.field) == ["图标大小", "环形样式（暂未支持）", "显示电池百分比", "底部槽位"])
        #expect(rows[0] == ThemeDiffRow(field: "图标大小", currentValue: "18 pt", newValue: "22 pt"))
        #expect(rows[1].currentValue == "—", "现值未知/不支持用占位符，不编造")
        #expect(rows[2] == ThemeDiffRow(field: "显示电池百分比", currentValue: "开", newValue: "关"))
        #expect(rows[3] == ThemeDiffRow(field: "底部槽位", currentValue: "音量点", newValue: "时钟"), "槽位 id 用注册表中文名")
        // 预览态尚未写库
        #expect(store.menuBarIconSize == 18)
        #expect(store.footerSlotID == "volume")
    }

    @Test func confirmImportAppliesAndReportsSkipped() {
        let store = SettingsStore(defaults: makeDefaults())
        let theme = ButlerTheme(
            appearance: ThemeAppearance(iconSize: 22, symbolScale: 1.4),
            footerSlotID: "clock"
        )
        let port = makePort(read: { _ in ThemeCodec.encode(theme) })
        port.beginImport(from: store)
        port.confirmImport(to: store)
        guard case .applied(let skipped) = port.importPhase else {
            Issue.record("应进已应用态，实际 \(port.importPhase)")
            return
        }
        #expect(store.menuBarIconSize == 22)
        #expect(store.footerSlotID == "clock")
        #expect(skipped == ["符号缩放（symbolScale）暂未支持"], "跳过项逐条可见（TH-05）")
        port.reset()
        #expect(port.importPhase == .idle)
    }

    @Test func exportWritesSnapshotAndImportRoundTrips() {
        let store = SettingsStore(defaults: makeDefaults())
        store.menuBarIconSize = 21
        store.showsBatteryPercentage = false
        store.footerSlotID = "clock"

        var written = Data()
        let exportURL = URL(fileURLWithPath: "/tmp/test-export.butler-theme")
        let exporter = makePort(pickExport: { exportURL }, write: { _, data in written = data })
        exporter.export(from: store)
        guard case .saved = exporter.exportOutcome else {
            Issue.record("导出应成功，实际 \(exporter.exportOutcome)")
            return
        }
        // 落盘字节可解码回同值主题（导出物即合法导入物）
        let decoded = try! JSONDecoder().decode(ButlerTheme.self, from: written)
        #expect(decoded == ThemeApplier.snapshot(from: store))

        // 用同一份字节走导入全流程：预览 3 行 → 确认 → 零跳过（导出只含本机支持字段）
        let target = SettingsStore(defaults: makeDefaults())
        #expect(target.menuBarIconSize == 18)  // 默认值待变更
        let importer = makePort(read: { _ in written })
        importer.beginImport(from: target)
        guard case .previewing(let rows) = importer.importPhase else {
            Issue.record("导入自家导出物应进预览")
            return
        }
        #expect(rows.count == 3)
        importer.confirmImport(to: target)
        guard case .applied(let skipped) = importer.importPhase else {
            Issue.record("应进已应用态")
            return
        }
        #expect(skipped.isEmpty, "往返零跳过")
        #expect(target.menuBarIconSize == 21)
        #expect(target.showsBatteryPercentage == false)
        #expect(target.footerSlotID == "clock")
        #expect(ThemeApplier.snapshot(from: target) == decoded, "apply(snapshot) 收敛：再导出字节稳定")
    }

    @Test func exportFailureAndCancelAreDistinct() {
        let store = SettingsStore(defaults: makeDefaults())
        // 面板取消 → idle（不是失败）
        let cancelled = makePort(pickExport: { nil })
        cancelled.export(from: store)
        #expect(cancelled.exportOutcome == .idle)
        // 写盘失败 → failed 带理由
        struct DiskFull: Error {}
        let failing = makePort(pickExport: { URL(fileURLWithPath: "/x") }, write: { _, _ in throw DiskFull() })
        failing.export(from: store)
        guard case .failed(let message) = failing.exportOutcome else {
            Issue.record("写失败应进 failed")
            return
        }
        #expect(message.contains("导出失败"))
        failing.dismissExportNotice()
        #expect(failing.exportOutcome == .idle)
    }

    // MARK: - T-209 分区布局编辑器

    @Test func panelLayoutPersistsAcrossReloadWithSanitizedFallback() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.panelLayout == .default, "首次启动全分区默认序")
        let custom = PanelLayout(
            visibleSections: [.battery, .thermal],
            order: [.thermal, .battery, .network, .volume, .bluetooth, .performance]
        )
        store.panelLayout = custom
        #expect(SettingsStore(defaults: defaults).panelLayout == custom)

        // 旧版本数据缺新分区 id / 有重复：sanitized 修复而非整体丢弃
        let stale = PanelLayout(visibleSections: [.battery, .battery], order: [.battery, .network, .network])
        defaults.set(try! JSONEncoder().encode(stale), forKey: "panelLayout")
        let repaired = SettingsStore(defaults: defaults).panelLayout
        #expect(repaired.isValid)
        #expect(repaired.order.first == .battery, "去重保序")
        #expect(repaired.order.count == PanelSectionID.allCases.count, "缺失分区按声明序补齐")
        #expect(repaired.visibleSections == [.battery], "重复显隐去重")

        // 完全坏数据兜底默认布局
        let garbage = makeDefaults()
        garbage.set(Data("junk".utf8), forKey: "panelLayout")
        #expect(SettingsStore(defaults: garbage).panelLayout == .default)
    }

    @Test func moveRespectsBoundsAndUnknownID() {
        let layout = PanelLayout(visibleSections: PanelSectionID.allCases, order: PanelSectionID.allCases)
        let first = PanelSectionID.allCases[0]
        let second = PanelSectionID.allCases[1]
        let last = PanelSectionID.allCases.last!

        // 首行上移 / 末行下移：越界原样返回（按钮侧 disabled，纯函数侧也要幂等）
        #expect(PanelLayoutEditor.move(layout, id: first, offset: -1) == layout)
        #expect(PanelLayoutEditor.move(layout, id: last, offset: 1) == layout)
        // 中间上移：相邻交换
        let moved = PanelLayoutEditor.move(layout, id: second, offset: -1)
        #expect(moved.order.first == second)
        #expect(moved.order[1] == first)
        #expect(moved.isValid)
        // 未知 id（不在此布局中）原样返回
        #expect(PanelLayoutEditor.move(layout, id: first, offset: 0) == layout)
        // 跨多步位移（测试通道；UI 只用 ±1）
        let jumped = PanelLayoutEditor.move(layout, id: second, offset: 3)
        #expect(jumped.order.firstIndex(of: second) == 4)
        #expect(jumped.isValid)
    }

    @Test func setVisibleKeepsSubsetLayoutInvariant() {
        let layout = PanelLayout.default
        let hidden = PanelLayoutEditor.setVisible(layout, id: .network, visible: false)
        #expect(!hidden.visibleSections.contains(.network))
        #expect(hidden.order.count == PanelSectionID.allCases.count, "显隐不动 order（显隐与排序解耦）")
        #expect(hidden.isValid, "visible 必须仍是 order 子集")

        // 再显示回来：幂等且恢复
        let restored = PanelLayoutEditor.setVisible(hidden, id: .network, visible: true)
        #expect(restored.visibleSections.contains(.network))
        #expect(restored.isValid)

        // 全部隐藏合法（弹层只剩壳）+ 重复显示幂等
        var current = layout
        for section in PanelSectionID.allCases {
            current = PanelLayoutEditor.setVisible(current, id: section, visible: false)
        }
        #expect(current.visibleSections.isEmpty)
        #expect(current.isValid)
        #expect(PanelLayoutEditor.setVisible(current, id: .battery, visible: false) == current)
    }
}
