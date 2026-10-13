import AppKit
import Foundation
import Testing

@testable import StatusButlerCore

// C2 弹层区 P2/P3（T-211 会议条 / T-212 养护页 / T-213 插件管理页 /
// T-216 Shortcuts 钉选 / T-221 更新扫描）。映射纯函数钉死边界，VM 集成走注入假件；
// 全部无窗口依赖（CI 无 WindowServer 也能全量跑）。
@MainActor
@Suite(.serialized)
struct PanelZoneP2Tests {

    // MARK: - 测试假件

    @MainActor
    final class NilBluetoothMonitor: BluetoothMonitoring {
        func read() async -> [BluetoothDeviceInfo] { [] }
    }

    @MainActor
    final class NilThermalMonitor: ThermalMonitoring {
        func read() async -> ThermalSnapshot? { nil }
    }

    /// openExternal 记录器（断言"打开过哪个 URL"；@MainActor 闭包匹配注入类型）
    @MainActor
    final class OpenURLRecorder {
        private(set) var urls: [URL] = []
        func handle(_ url: URL) { urls.append(url) }
    }

    /// 养护页读假件（静态序列；CareDailyPoint/EventRow 都是纯值）
    final class FakeCareReader: BatteryCareReading, @unchecked Sendable {
        let daily: [CareDailyPoint]
        let events: [EventRow]
        init(daily: [CareDailyPoint], events: [EventRow]) {
            self.daily = daily
            self.events = events
        }
        func careDailySeries() -> [CareDailyPoint] { daily }
        func allEvents() -> [EventRow] { events }
    }

    /// 电池详情读假件（IORegistry 层的可注入替身）
    final class FakeBatteryDetailsReader: BatteryDetailsReading, @unchecked Sendable {
        let details: BatteryDetails?
        init(_ details: BatteryDetails?) { self.details = details }
        func read() async -> BatteryDetails? { details }
    }

    /// 插件列表可变假件（重载记录 + 行内容可换，验证刷新反映新计数）
    final class MutablePluginState: @unchecked Sendable {
        // @unchecked 论证：rows/reloads 仅在 NSLock 内读写
        private let lock = NSLock()
        private var rowsValue: [PluginRowState] = []
        private var reloadIDsValue: [String] = []

        func setRows(_ rows: [PluginRowState]) {
            lock.withLock { rowsValue = rows }
        }

        var reloadIDs: [String] { lock.withLock { reloadIDsValue } }

        func call() -> [PluginRowState] { lock.withLock { rowsValue } }

        func reload(_ id: String) {
            lock.withLock { reloadIDsValue.append(id) }
        }
    }

    /// 会议条可变假件（静音态经同一锁，验证切换后重拉生效）
    final class MutableMeetingState: @unchecked Sendable {
        // @unchecked 论证：muted 仅在 NSLock 内读写
        private let lock = NSLock()
        private var muted = false

        var isMuted: Bool { lock.withLock { muted } }

        func toggle() -> Bool? {
            lock.withLock {
                muted.toggle()
                return muted
            }
        }

        func providerState(now: Date) -> MeetingBarState? {
            MeetingBarMapping.state(
                from: EventTimeline(events: [Self.meetingEvent(now: now)]),
                now: now,
                isInputMuted: isMuted
            )
        }

        static func meetingEvent(now: Date) -> CalendarEvent {
            CalendarEvent(
                id: "m-1",
                title: "周会",
                startDate: now.addingTimeInterval(-600),
                endDate: now.addingTimeInterval(1500),
                isAllDay: false,
                meetingURL: URL(string: "https://zoom.us/j/123456")!
            )
        }
    }

    /// Homebrew 版本源假件（token → 版本表；缺 token → nil）
    final class FakeCaskFetcher: CaskVersionFetching, @unchecked Sendable {
        let versions: [String: String]
        init(versions: [String: String]) { self.versions = versions }
        func latestVersion(token: String) async -> String? { versions[token] }
    }

    private func makeStore() -> SystemStatusStore {
        SystemStatusStore(
            battery: StaticBatteryMonitor(.battery(level: 66, charging: false)),
            wifi: StaticWiFiMonitor(.wifi(ssid: "Home", signalBars: 3)),
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
    }

    private func makeVM(
        bypassPollInterval: Duration = .seconds(60),
        meetingBarProvider: MeetingBarStateProvider? = nil,
        meetingMuteToggler: MeetingMuteToggler? = nil,
        batteryCareReader: (any BatteryCareReading)? = nil,
        batteryDetails: (any BatteryDetailsReading)? = nil,
        pluginListProvider: PluginListProvider? = nil,
        pluginReloadAction: PluginReloadAction? = nil,
        shortcutsListProvider: ShortcutsListProvider? = nil,
        brewListProvider: (@Sendable () -> String)? = nil,
        caskVersionFetcher: (any CaskVersionFetching)? = nil,
        openExternal: (@MainActor (URL) -> Void)? = nil
        ) -> PanelViewModel {
        PanelViewModel(
            store: makeStore(),
            bluetooth: NilBluetoothMonitor(),
            thermal: NilThermalMonitor(),
            bypassPollInterval: bypassPollInterval,
            batteryDetails: batteryDetails,
            openExternal: openExternal,
            meetingBarProvider: meetingBarProvider,
            meetingMuteToggler: meetingMuteToggler,
            batteryCareReader: batteryCareReader,
            pluginListProvider: pluginListProvider,
            pluginReloadAction: pluginReloadAction,
            shortcutsListProvider: shortcutsListProvider,
            brewListProvider: brewListProvider,
            caskVersionFetcher: caskVersionFetcher
        )
    }

    /// 轮询等待（VM 异步任务落定的确定性收口；上限兜底防挂死）
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - T-211 会议条（inMeeting 判定 / 一键入会 URL / 静音闭包）

    @Test func meetingBarMappingDecidesInProgressMeetingWithJoinLink() {
        let now = Date()
        func event(
            id: String,
            start: TimeInterval,
            end: TimeInterval,
            url: URL? = nil,
            allDay: Bool = false
        ) -> CalendarEvent {
            CalendarEvent(
                id: id, title: id, startDate: now.addingTimeInterval(start),
                endDate: now.addingTimeInterval(end), isAllDay: allDay, meetingURL: url
            )
        }
        let zoom = URL(string: "https://zoom.us/j/123456")!
        let inMeeting = event(id: "m1", start: -600, end: 1500, url: zoom)
        let noLink = event(id: "m2", start: -300, end: 900)
        let future = event(id: "m3", start: 300, end: 1800, url: zoom)
        let allDay = event(id: "m4", start: -600, end: 1500, url: zoom, allDay: true)

        // 带链接的进行中事件 → 会议条（剩余 1500s = "25分"）
        let state = MeetingBarMapping.state(
            from: EventTimeline(events: [noLink, future, allDay, inMeeting]),
            now: now,
            isInputMuted: false
        )
        #expect(state?.eventID == "m1")
        #expect(state?.joinURL == zoom)
        #expect(state?.remainingText == "25分")
        #expect(state?.isInputMuted == false)

        // 无链接 / 未开始 / 全天：都不构成会议条
        #expect(MeetingBarMapping.state(
            from: EventTimeline(events: [noLink]), now: now, isInputMuted: nil
        ) == nil)
        #expect(MeetingBarMapping.state(
            from: EventTimeline(events: [future]), now: now, isInputMuted: nil
        ) == nil)
        #expect(MeetingBarMapping.state(
            from: EventTimeline(events: [allDay]), now: now, isInputMuted: nil
        ) == nil)
        #expect(MeetingBarMapping.state(
            from: EventTimeline(events: []), now: now, isInputMuted: nil
        ) == nil)
    }

    @Test func meetingBarPollsWhileVisibleAndJoinOpensProviderURL() async {
        let box = MutableMeetingState()
        let recorder = OpenURLRecorder()
        let vm = makeVM(
            bypassPollInterval: .milliseconds(80),
            meetingBarProvider: { box.providerState(now: Date()) },
            openExternal: { recorder.handle($0) }
        )
        #expect(!vm.showsMeetingBar)  // 未接线样即时读也无数据
        vm.panelDidAppear()
        await waitUntil { vm.meetingBar != nil }
        #expect(vm.showsMeetingBar)
        #expect(vm.meetingBar?.joinURL.absoluteString == "https://zoom.us/j/123456")

        vm.joinCurrentMeeting()
        #expect(recorder.urls == [URL(string: "https://zoom.us/j/123456")!])

        // 消失即停（能效铁律：旁路轮询不越界）
        vm.panelWillDisappear()
        #expect(!vm.isBypassSamplingActive)
    }

    @Test func meetingMuteTogglePassesThroughClosureAndRefreshesBar() async {
        let box = MutableMeetingState()
        let vm = makeVM(
            meetingBarProvider: { box.providerState(now: Date()) },
            meetingMuteToggler: { box.toggle() }
        )
        vm.refreshMeetingBar()  // 未开轮询直接拉一次（确定性路径）
        #expect(vm.isMeetingMuteActionAvailable)

        let result = vm.toggleMeetingMute()
        #expect(result == true)  // 闭包返回切换后态
        #expect(vm.meetingBar?.isInputMuted == true)  // 立即重拉，徽标回显
        _ = vm.toggleMeetingMute()
        #expect(vm.meetingBar?.isInputMuted == false)

        // 未接线静音闭包：按钮面不可用，toggle 返回 nil 不伪装
        let noToggler = makeVM(meetingBarProvider: { box.providerState(now: Date()) })
        noToggler.refreshMeetingBar()
        #expect(!noToggler.isMeetingMuteActionAvailable)
        #expect(noToggler.toggleMeetingMute() == nil)

        // provider 未接线：整条隐藏（诚实降级），入会/静音都是安全 no-op
        let unwired = makeVM()
        unwired.panelDidAppear()
        #expect(!unwired.showsMeetingBar)
        unwired.joinCurrentMeeting()
        #expect(unwired.toggleMeetingMute() == nil)
    }

    // MARK: - T-212 养护页（月度小结聚合 / 状态行映射 / VM 按需加载）

    @Test func careMonthlySummariesAggregateByMonth() {
        let daily = [
            CareDailyPoint(date: "2026-09-28", batteryCapacityPercent: 95, cycleCount: 100),
            CareDailyPoint(date: "2026-09-30", batteryCapacityPercent: 94, cycleCount: 102),
            CareDailyPoint(date: "2026-10-02", batteryCapacityPercent: 93, cycleCount: 105),
            CareDailyPoint(date: "2026-10-12", batteryCapacityPercent: 92, cycleCount: 110),
        ]
        let events = [
            EventRow(id: 1, at: "2026-09-29T08:00:00Z", kind: "chargeStart", detail: nil),
            EventRow(id: 2, at: "2026-10-01T09:00:00Z", kind: "chargeStart", detail: nil),
            EventRow(id: 3, at: "2026-10-05T10:00:00Z", kind: "chargeStart", detail: nil),
            EventRow(id: 4, at: "2026-10-06T11:00:00Z", kind: "wifiConnect", detail: "Home"),
        ]
        let summaries = BatteryCareMapping.monthlySummaries(daily: daily, events: events)
        #expect(summaries.map(\.monthKey) == ["2026-09", "2026-10"])

        let september = summaries[0]
        #expect(september.recordedDays == 2)
        #expect(september.averageCapacityPercent == 95)  // (95+94)/2=94.5 四舍五入
        #expect(september.capacityDelta == -1)
        #expect(september.cycleDelta == 2)
        #expect(september.chargeStartCount == 1)

        let october = summaries[1]
        #expect(october.averageCapacityPercent == 93)
        #expect(october.capacityDelta == -1)
        #expect(october.cycleDelta == 5)
        #expect(october.chargeStartCount == 2)  // wifiConnect 不计入

        // 单点月：均值有、增量为 nil（一个点算不出"变化"）；空输入 → 空表
        let single = BatteryCareMapping.monthlySummaries(
            daily: [CareDailyPoint(date: "2026-11-01", batteryCapacityPercent: 90, cycleCount: 1)],
            events: []
        )
        #expect(single.count == 1)
        #expect(single[0].capacityDelta == nil && single[0].cycleDelta == nil)
        #expect(single[0].averageCapacityPercent == 90)
        #expect(BatteryCareMapping.monthlySummaries(daily: [], events: []).isEmpty)
        // 只有事件没有 daily 的月：天数 0、均值 nil、充电计数仍归账
        let eventOnly = BatteryCareMapping.monthlySummaries(daily: [], events: events)
        #expect(eventOnly.map(\.monthKey) == ["2026-09", "2026-10"])
        #expect(eventOnly.allSatisfy { $0.recordedDays == 0 && $0.averageCapacityPercent == nil })
    }

    @Test func careOverviewRowMappingsAreHonestAboutMissingChargeLimit() {
        #expect(BatteryCareMapping.chargeLimitMissingText == "—")
        #expect(BatteryCareMapping.chargingStateText(externalConnected: false, isCharging: false) == "使用电池")
        #expect(BatteryCareMapping.chargingStateText(externalConnected: true, isCharging: false) == "外接电源（未充电）")
        #expect(BatteryCareMapping.chargingStateText(externalConnected: true, isCharging: true) == "充电中")
        // 曲线点位适配：循环数列被丢弃，容量列原样进 T-207 折线口径
        let points = BatteryCareMapping.chartPoints(from: [
            CareDailyPoint(date: "2026-10-01", batteryCapacityPercent: 93, cycleCount: 100),
        ])
        #expect(points == [DailyMetricPoint(date: "2026-10-01", batteryCapacityPercent: 93)])
    }

    @Test func carePageLoadsOnPushAndEntryGatesOnReader() async {
        let reader = FakeCareReader(
            daily: [
                CareDailyPoint(date: "2026-10-11", batteryCapacityPercent: 94, cycleCount: 100),
                CareDailyPoint(date: "2026-10-12", batteryCapacityPercent: 93, cycleCount: 101),
            ],
            events: [
                EventRow(id: 1, at: "2026-10-12T08:00:00Z", kind: "chargeStart", detail: nil),
            ]
        )
        let details = FakeBatteryDetailsReader(BatteryDetails(
            cycleCount: 101, maxCapacity: 4800, designCapacity: 5100,
            voltageMillivolts: 11800, amperageMilliamps: -1500,
            externalConnected: true, isCharging: true
        ))
        let vm = makeVM(batteryCareReader: reader, batteryDetails: details)
        #expect(vm.showsBatteryCareEntryRow)
        vm.push(.batteryCare)
        #expect(vm.currentRoute == .batteryCare)
        #expect(vm.careDaily.count == 2)
        #expect(vm.careMonthly.count == 1)
        #expect(vm.careMonthly.first?.chargeStartCount == 1)
        #expect(vm.careMonthly.first?.capacityDelta == -1)
        // 电池详情是异步读，落定后养护总览行有数（假 IORegistry 的注入路径）
        await waitUntil { vm.batteryDetail != nil }
        #expect(vm.batteryDetail?.cycleCount == 101)

        // 读服务未接线：不给入口，push 也不读（诚实降级）
        let unwired = makeVM()
        #expect(!unwired.showsBatteryCareEntryRow)
        unwired.push(.batteryCare)
        #expect(unwired.careDaily.isEmpty && unwired.careMonthly.isEmpty)
    }

    // MARK: - T-213 插件管理页（健康分档 / 复位决策 / VM 刷新与重载）

    @Test func pluginHealthTiersFollowTripleStrikeRule() {
        #expect(PluginPanelMapping.health(failureCount: 0) == .healthy)
        #expect(PluginPanelMapping.health(failureCount: 1) == .degraded)
        #expect(PluginPanelMapping.health(failureCount: 2) == .degraded)
        #expect(PluginPanelMapping.health(failureCount: 3) == .stopped)
        #expect(PluginPanelMapping.health(failureCount: 7) == .stopped)
        // 只有停用态需要"复位才能恢复"；健康/连败态重载只是手动刷新
        #expect(PluginPanelMapping.needsReset(.stopped))
        #expect(!PluginPanelMapping.needsReset(.healthy))
        #expect(!PluginPanelMapping.needsReset(.degraded))
        // 说明文案与三连击门限同源（门限数字写进文案，防两处漂移）
        #expect(PluginPanelMapping.tripleStrikeExplanation.contains("3"))
    }

    @Test func pluginRowsMapManifestFieldsAndFailureCounts() {
        let manifest = PluginManifest(
            id: "disk", name: "磁盘用量", interpreter: "/bin/sh",
            refreshHintSeconds: 30, author: "林"
        )
        let scriptURL = URL(fileURLWithPath: "/tmp/disk/script.sh")
        let rows = PluginPanelMapping.rows(from: [(manifest, scriptURL)]) { id in
            id == "disk" ? 3 : 0
        }
        #expect(rows.count == 1)
        #expect(rows[0].id == "disk")
        #expect(rows[0].name == "磁盘用量")
        #expect(rows[0].author == "林")
        #expect(rows[0].interpreter == "/bin/sh")
        #expect(rows[0].refreshHintSeconds == 30)
        #expect(rows[0].failureCount == 3)
        #expect(rows[0].health == .stopped)  // 三连击停用
    }

    @Test func pluginManagerRefreshesRowsAndReloadResetsViaClosure() {
        let state = MutablePluginState()
        state.setRows([
            PluginRowState(id: "disk", name: "磁盘用量", author: nil,
                           interpreter: "/bin/sh", refreshHintSeconds: 30, failureCount: 3),
        ])
        let vm = makeVM(
            pluginListProvider: { state.call() },
            pluginReloadAction: { state.reload($0) }
        )
        #expect(vm.showsPluginEntryRow)
        vm.push(.plugins)
        #expect(vm.pluginRows.count == 1)
        #expect(vm.pluginRows[0].health == .stopped)

        // 重载：闭包收到 id（主线在闭包里 runner.reset），重扫反映复位后的计数
        state.setRows([
            PluginRowState(id: "disk", name: "磁盘用量", author: nil,
                           interpreter: "/bin/sh", refreshHintSeconds: 30, failureCount: 0),
        ])
        vm.reloadPlugin("disk")
        #expect(state.reloadIDs == ["disk"])
        #expect(vm.pluginRows[0].failureCount == 0)
        #expect(vm.pluginRows[0].health == .healthy)

        // 未接线：入口隐藏，刷新/重载都是安全 no-op
        let unwired = makeVM()
        #expect(!unwired.showsPluginEntryRow)
        unwired.push(.plugins)
        #expect(unwired.pluginRows.isEmpty)
        unwired.reloadPlugin("disk")  // 无动作闭包，不崩不伪装
    }

    // MARK: - T-216 Shortcuts 钉选（URL 构造 / 钉选执行 / App 入口）

    @Test func shortcutLinkConstructionEncodesNames() {
        #expect(ShortcutLink.appURL.absoluteString == "shortcuts://")
        // 中文名百分号编码（钉选名直接来自用户的 Shortcuts 命名）
        let url = ShortcutLink.runURL(name: "备份文件")
        #expect(url?.absoluteString == "shortcuts://run-shortcut?name=%E5%A4%87%E4%BB%BD%E6%96%87%E4%BB%B6")
        // 空格等保留字符：编码后可原样解回（round-trip 不丢名）
        let spaced = ShortcutLink.runURL(name: "a b")
        #expect(spaced != nil)
        let parsed = spaced.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(parsed?.queryItems?.first?.name == "name")
        #expect(parsed?.queryItems?.first?.value == "a b")
        // ASCII 名不加画蛇添足的编码
        #expect(ShortcutLink.runURL(name: "backup")?.absoluteString
                == "shortcuts://run-shortcut?name=backup")
    }

    @Test func shortcutsPinsInjectAndRunThroughDeepLink() async {
        let pin = ShortcutPin(id: "s1", name: "备份文件")
        let recorder = OpenURLRecorder()
        let vm = makeVM(
            shortcutsListProvider: { [pin] },
            openExternal: { recorder.handle($0) }
        )
        #expect(vm.isShortcutsEntryVisible)
        vm.panelDidAppear()
        #expect(vm.pinnedShortcuts == [pin])

        vm.runShortcut(pin)
        #expect(recorder.urls.last?.absoluteString
                == "shortcuts://run-shortcut?name=%E5%A4%87%E4%BB%BD%E6%96%87%E4%BB%B6")

        // "Shortcuts…"按钮出口：打开 Shortcuts App 本体（无枚举 API 的诚实降级）
        vm.openShortcutsApp()
        #expect(recorder.urls.last == URL(string: "shortcuts://")!)

        // 未注入名单：入口隐藏、无钉选（不虚构系统枚举结果）
        let unwired = makeVM()
        #expect(!unwired.isShortcutsEntryVisible)
        unwired.panelDidAppear()
        #expect(unwired.pinnedShortcuts.isEmpty)
    }

    // MARK: - T-221 更新扫描（brew 解析 / 比对告警 / 三道闸 / VM 流程）

    @Test func brewListParserHandlesVersionsAndBareTokens() {
        let output = """
        google-chrome 120.0.6099.129
        visual-studio-code 1.85.1
        wezterm

        firefox
        """
        let casks = BrewListParser.parse(output)
        #expect(casks.map(\.name) == ["google-chrome", "visual-studio-code", "wezterm", "firefox"])
        #expect(casks.map(\.version) == ["120.0.6099.129", "1.85.1", nil, nil])
        #expect(BrewListParser.parse("").isEmpty)
        // 双版本残留（重装）：取首个为有效版本
        let multi = BrewListParser.parse("vlc 3.0.20 3.0.18")
        #expect(multi == [InstalledCask(name: "vlc", version: "3.0.20")])
    }

    @Test func caskComparisonFlagsOutdatedAndSummarizesAlerts() {
        let chrome = InstalledCask(name: "google-chrome", version: "120.0")
        #expect(CaskComparison.compare(installed: chrome, latestVersion: "121.0").isOutdated == true)
        #expect(CaskComparison.compare(installed: chrome, latestVersion: "120.0").isOutdated == false)
        // 任一侧缺测 → 无法判定（nil），绝不猜"最新"
        #expect(CaskComparison.compare(installed: chrome, latestVersion: nil).isOutdated == nil)
        #expect(CaskComparison.compare(
            installed: InstalledCask(name: "wezterm", version: nil),
            latestVersion: "20230712"
        ).isOutdated == nil)

        let results = [
            CaskComparison.compare(installed: chrome, latestVersion: "121.0"),
            CaskComparison.compare(installed: InstalledCask(name: "firefox", version: "118.0"),
                                   latestVersion: "118.0"),
            CaskComparison.compare(installed: InstalledCask(name: "wezterm", version: nil),
                                   latestVersion: nil),
        ]
        #expect(CaskComparison.summaryText(for: results) == "发现 1 个可更新")
        #expect(CaskComparison.summaryText(for: [results[1]]) == "已安装的 cask 均为最新")
        #expect(CaskComparison.summaryText(for: []) == "未发现已安装的 cask")
        // 无确证可更新但存在缺测项 → 不宣称"均为最新"
        #expect(CaskComparison.summaryText(for: Array(results.dropFirst())) == "无确证的可更新项（部分版本无法比对）")
        // 官网深链
        #expect(results[0].homepageURL?.absoluteString == "https://formulae.brew.sh/cask/google-chrome")
    }

    @Test func updateNetworkPolicyGatesURLWhitelistAndTokenSafety() {
        // 闸 1：https + 域名白名单
        #expect(UpdateNetworkPolicy.validateURL(
            URL(string: "https://formulae.brew.sh/api/cask/firefox.json")!
        ))
        #expect(!UpdateNetworkPolicy.validateURL(
            URL(string: "http://formulae.brew.sh/api/cask/firefox.json")!
        ))  // http 降级拒绝
        #expect(!UpdateNetworkPolicy.validateURL(
            URL(string: "https://evil.example.com/api/cask/firefox.json")!
        ))  // 白名单外拒绝
        #expect(!UpdateNetworkPolicy.validateURL(
            URL(string: "https://formulae.brew.sh.evil.com/cask.json")!
        ))  // 前缀仿冒域不命中白名单
        // token 安全闸：路径/查询注入字符直接拒绝构造
        #expect(UpdateNetworkPolicy.caskInfoURL(token: "google-chrome")?.absoluteString
                == "https://formulae.brew.sh/api/cask/google-chrome.json")
        #expect(UpdateNetworkPolicy.caskInfoURL(token: "a/b") == nil)
        #expect(UpdateNetworkPolicy.caskInfoURL(token: "a?b") == nil)
        #expect(UpdateNetworkPolicy.caskInfoURL(token: "Bad") == nil)  // 大写非 cask token 形态
        #expect(UpdateNetworkPolicy.caskInfoURL(token: "") == nil)
        // 深链同源校验
        #expect(CaskComparison.caskPageURL(name: "google-chrome")?.absoluteString
                == "https://formulae.brew.sh/cask/google-chrome")
        #expect(CaskComparison.caskPageURL(name: "a b") == nil)
    }

    @Test func caskInfoJSONVersionExtraction() {
        #expect(CaskInfoParser.parseVersion(
            fromJSON: Data(#"{"token":"firefox","version":"118.0.2"}"#.utf8)
        ) == "118.0.2")
        #expect(CaskInfoParser.parseVersion(fromJSON: Data(#"{"token":"x"}"#.utf8)) == nil)
        #expect(CaskInfoParser.parseVersion(fromJSON: Data(#"{"version":""}"#.utf8)) == nil)
        #expect(CaskInfoParser.parseVersion(fromJSON: Data("not json".utf8)) == nil)
        #expect(CaskInfoParser.parseVersion(fromJSON: Data(#"{"version":118}"#.utf8)) == nil)
    }

    @Test func updateScanFlowChecksAndDeepLinksHomepage() async {
        let brewOutput = "google-chrome 120.0\nfirefox 118.0\nwezterm\n"
        let recorder = OpenURLRecorder()
        let vm = makeVM(
            brewListProvider: { brewOutput },
            caskVersionFetcher: FakeCaskFetcher(versions: [
                "google-chrome": "121.0",  // 可更新
                "firefox": "118.0",        // 最新
                // wezterm 无远端记录 → 无法比对
            ]),
            openExternal: { recorder.handle($0) }
        )
        #expect(vm.showsUpdateScanEntryRow)
        vm.push(.updateScan)  // 首次进入自动查一轮
        #expect(vm.isUpdateScanning)
        await waitUntil { !vm.isUpdateScanning }
        #expect(vm.updateResults.count == 3)
        #expect(vm.updateResults.first { $0.name == "google-chrome" }?.isOutdated == true)
        #expect(vm.updateResults.first { $0.name == "firefox" }?.isOutdated == false)
        #expect(vm.updateResults.first { $0.name == "wezterm" }?.isOutdated == nil)
        #expect(vm.updateScanSummary == "发现 1 个可更新")

        // 官网深链出口
        let chrome = vm.updateResults.first { $0.name == "google-chrome" }!
        vm.openCaskHomepage(chrome)
        #expect(recorder.urls.last?.absoluteString == "https://formulae.brew.sh/cask/google-chrome")

        // 结果已非空：重进页面不自动重查（能效——重查是显式按钮）
        vm.popToRoot()
        vm.push(.updateScan)
        #expect(!vm.isUpdateScanning)

        // 未接线（清单与版本源缺一）：入口隐藏，checkForUpdates 安全 no-op
        let unwired = makeVM()
        #expect(!unwired.showsUpdateScanEntryRow)
        unwired.checkForUpdates()
        #expect(!unwired.isUpdateScanning)
        #expect(unwired.updateResults.isEmpty)
    }
}
