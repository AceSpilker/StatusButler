import Foundation
import Testing
@testable import StatusButlerCore

// T-041：日程倒数 + 会议助手——链接检测规则表 / 倒计时简写边界 / nextEvent 过滤 /
// 会议中判定与静音占位 / 授权被拒降级 / 排序与空态。
// 纪律：全用 FakeEventStore 注入（CI runner 无日历权限），不碰 LiveEventStore。

@Suite struct CalendarTests {
    /// 固定时基：全部断言只做时长运算，不受当前时刻/时区影响
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var snapshot: StatusSnapshot {
        StatusSnapshot(
            battery: .battery(level: 66, charging: false),
            link: .wifi(ssid: "H", signalBars: 4),
            volume: VolumeState(level: 50, isMuted: false)
        )
    }

    private func event(
        id: String = "e1",
        title: String = "评审会",
        startOffset: TimeInterval,
        duration: TimeInterval = 3600,
        isAllDay: Bool = false,
        url: URL? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(startOffset + duration),
            isAllDay: isAllDay,
            meetingURL: url
        )
    }

    // MARK: - MeetingLinkDetector 规则表（MTG-01）

    @Test func detectsZoomWebLinkWithPassword() throws {
        let url = try #require(MeetingLinkDetector.meetingURL(
            from: "和客户对齐",
            notes: "入会：https://us05web.zoom.us/j/987654321?pwd=abcDEFghi，请准时"
        ))
        // 企业子域 + ?pwd= 密码完整保留（丢了密码会卡在入会口令页）
        #expect(url.absoluteString == "https://us05web.zoom.us/j/987654321?pwd=abcDEFghi")
    }

    @Test func detectsZoomClientDeepLinks() throws {
        // 规格钉死的 zoom:// 与客户端实际注册的 zoommtg:// 都要认
        let zoom = try #require(MeetingLinkDetector.meetingURL(from: "zoom://zoom.us/join?confno=123456", notes: nil))
        #expect(zoom.scheme == "zoom")
        let zoommtg = try #require(MeetingLinkDetector.meetingURL(from: "周会", notes: "zoommtg://zoom.us/start?confno=987"))
        #expect(zoommtg.scheme == "zoommtg")
    }

    @Test func detectsGoogleMeet() throws {
        let url = try #require(MeetingLinkDetector.meetingURL(from: "https://meet.google.com/abc-defg-hij", notes: nil))
        #expect(url.host == "meet.google.com")
        #expect(url.path == "/abc-defg-hij")
    }

    @Test func detectsTeamsDeepLink() throws {
        let url = try #require(MeetingLinkDetector.meetingURL(
            from: "跨组同步",
            notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
        ))
        #expect(url.host == "teams.microsoft.com")
        #expect(url.path.hasPrefix("/l/meetup-join/"))
    }

    @Test func detectsTencentMeetingWebAndClientLink() throws {
        // 网页入会 + 中文逗号收尾剥除
        let web = try #require(MeetingLinkDetector.meetingURL(from: "https://meeting.tencent.com/dm/AbCd1234，勿迟到", notes: nil))
        #expect(web.absoluteString == "https://meeting.tencent.com/dm/AbCd1234")
        // 客户端深链（官方 scheme 为 wemeet）
        let deep = try #require(MeetingLinkDetector.meetingURL(from: "wemeet://join?code=AbCd1234", notes: nil))
        #expect(deep.scheme == "wemeet")
    }

    @Test func detectsFeishuAndLarkJoinLinks() throws {
        #expect(MeetingLinkDetector.meetingURL(from: "飞书会 https://vc.feishu.cn/j/901234567", notes: nil)?.host == "vc.feishu.cn")
        #expect(MeetingLinkDetector.meetingURL(from: "Lark https://vc.larksuite.com/j/901234567", notes: nil)?.host == "vc.larksuite.com")
    }

    @Test func plainTextYieldsNoLink() {
        #expect(MeetingLinkDetector.meetingURL(from: "和产品过需求，会议室 A", notes: "带上电脑") == nil)
        #expect(MeetingLinkDetector.meetingURL(from: "1:1", notes: nil) == nil)
        #expect(MeetingLinkDetector.meetingURL(from: "", notes: nil) == nil)
    }

    @Test func lookalikeHostsAreRejected() {
        // 服务域藏在路径里的仿冒
        #expect(MeetingLinkDetector.meetingURL(from: "https://evil.example.com/zoom.us/j/123", notes: nil) == nil)
        // 服务域正确但非入会路径
        #expect(MeetingLinkDetector.meetingURL(from: "https://zoom.us/profile", notes: nil) == nil)
        // 相邻域拼贴（后缀域不是子域）
        #expect(MeetingLinkDetector.meetingURL(from: "https://meet.google.com.evil.com/abc-defg-hij", notes: nil) == nil)
    }

    @Test func titleTakesPriorityOverNotes() throws {
        let url = try #require(MeetingLinkDetector.meetingURL(
            from: "站会 https://meet.google.com/sta-ndup-x1",
            notes: "备用：https://meeting.tencent.com/dm/backup99"
        ))
        #expect(url.host == "meet.google.com")
    }

    // MARK: - 倒计时简写边界（CAL-01 规格）

    @Test func countdownMinuteFormatBoundaries() {
        #expect(EventTimeline.countdownText(next: event(startOffset: 1440), now: now) == "24分")
        #expect(EventTimeline.countdownText(next: event(startOffset: 1500), now: now) == "25分")
        // 24.5 分半分钟向上取整 → "25分"
        #expect(EventTimeline.countdownText(next: event(startOffset: 1470), now: now) == "25分")
    }

    @Test func countdownHourFormatBoundaries() {
        // 满一小时改时制：59 分仍是分制，61 分 → 1.0 时（规格钉死）
        #expect(EventTimeline.countdownText(next: event(startOffset: 3540), now: now) == "59分")
        #expect(EventTimeline.countdownText(next: event(startOffset: 3660), now: now) == "1.0时")
        #expect(EventTimeline.countdownText(next: event(startOffset: 5400), now: now) == "1.5时")
        // 已开始的事件防御性归 0，不出现负数
        #expect(EventTimeline.countdownText(next: event(startOffset: -120), now: now) == "0分")
    }

    // MARK: - EventTimeline 纯查询

    @Test func timelineSortsByStartDate() {
        let timeline = EventTimeline(events: [
            event(id: "late", startOffset: 7200),
            event(id: "soon", startOffset: 600),
            event(id: "mid", startOffset: 3600),
        ])
        #expect(timeline.events.map(\.id) == ["soon", "mid", "late"])
    }

    @Test func nextEventSkipsAllDayExpiredAndBeyondWindow() {
        let timeline = EventTimeline(events: [
            event(id: "allDay", startOffset: 1800, isAllDay: true),   // 全天 → 跳过
            event(id: "expired", startOffset: -7200, duration: 3600), // 已结束 → 跳过
            event(id: "inProgress", startOffset: -600, duration: 3600), // 进行中不算"下一件" → 跳过
            event(id: "far", startOffset: 25 * 3600),                 // 超 24h 窗口 → 跳过
            event(id: "next", startOffset: 1800, duration: 1800),
        ])
        #expect(timeline.nextEvent(now: now)?.id == "next")
        // 空态
        #expect(EventTimeline(events: []).nextEvent(now: now) == nil)
    }

    @Test func busyUntilTakesLatestEndOfOverlaps() {
        // 两场重叠：45 分钟前开始的 60 分钟会 + 15 分钟前开始的 90 分钟会 → 忙到最晚结束
        let timeline = EventTimeline(events: [
            event(id: "a", startOffset: -2700, duration: 3600),
            event(id: "b", startOffset: -900, duration: 5400),
        ])
        #expect(timeline.busyUntil(now: now) == now.addingTimeInterval(4500))
        // 空闲 → nil；全天事件不制造"忙碌"（与 CAL-01 不倒数同口径）
        #expect(EventTimeline(events: []).busyUntil(now: now) == nil)
        #expect(EventTimeline(events: [event(startOffset: -1800, isAllDay: true)]).busyUntil(now: now) == nil)
    }

    // MARK: - MeetingCenter（MTG-02）

    @Test func inMeetingRequiresInProgressAndLink() {
        let zoom = URL(string: "https://zoom.us/j/123")!
        let center = MeetingCenter(events: [
            event(id: "past", startOffset: -7200, duration: 3600, url: zoom),  // 已结束
            event(id: "future", startOffset: 1800, url: zoom),                  // 未开始
            event(id: "plain", startOffset: -600, duration: 3600),              // 进行中但无链接
            event(id: "current", startOffset: -1200, duration: 3600, url: zoom), // 进行中 + 链接
        ])
        #expect(center.inMeeting(now: now))
        #expect(center.currentMeeting(now: now)?.id == "current")
        // 剩余 2400s = 40 分
        #expect(center.remainingText(now: now) == "40分")
    }

    @Test func idleOrLinklessMeetingIsNotInMeeting() {
        let center = MeetingCenter(events: [event(startOffset: -600, duration: 3600)]) // 进行中无链接
        #expect(!center.inMeeting(now: now))
        #expect(center.currentMeeting(now: now) == nil)
        #expect(center.remainingText(now: now) == nil)
        #expect(MeetingCenter(events: []).inMeeting(now: now) == false)
    }

    @Test func toggleMuteGoesThroughInjectedController() throws {
        let zoom = URL(string: "https://zoom.us/j/123")!
        let inMeetingEvent = [event(startOffset: -300, duration: 3600, url: zoom)]
        // 未接线 → 动作不可用（T-041b 注入 CoreAudio 实现前）
        #expect(try MeetingCenter(events: inMeetingEvent).toggleMute(now: now) == nil)
        // 接线后切换并回读新态
        let mute = FakeMuteController()
        let center = MeetingCenter(events: inMeetingEvent, muteController: mute)
        #expect(try center.toggleMute(now: now) == true)
        #expect(mute.isInputMuted)
        #expect(try center.toggleMute(now: now) == false)
        #expect(!mute.isInputMuted)
        // 不在会中 → 即使接了控制器也不动麦克风
        let idleCenter = MeetingCenter(events: [event(startOffset: 1800, url: zoom)], muteController: mute)
        #expect(try idleCenter.toggleMute(now: now) == nil)
        #expect(!mute.isInputMuted)
    }

    // MARK: - CalendarSlot（FakeEventStore 注入）

    @Test func slotShowsCountdownWithoutTitle() async {
        let slot = CalendarSlot(provider: FakeEventStore(events: [event(title: "评审会", startOffset: 1500)]))
        #expect(slot.id == "calendarCountdown")
        await slot.refresh(now: now)
        let scene = slot.scene(snapshot: snapshot, now: now)
        #expect(scene?.symbol == "calendar")
        #expect(scene?.valueText == "25分")
        // CAL-03 隐私红线：槽位永不携带标题（标题只进面板层）
        #expect(scene?.valueText?.contains("评审会") != true)
    }

    @Test func slotReturnsNilWhenNoEvents() async {
        let slot = CalendarSlot(provider: FakeEventStore(events: []))
        await slot.refresh(now: now)
        #expect(slot.scene(snapshot: snapshot, now: now) == nil)
    }

    @Test func slotDegradesToNilWhenDenied() async {
        // CAL-04 授权被拒路径：先有数据 → 被拒 → 缓存清空，槽位降级 nil（其余功能不受影响）
        let fake = FakeEventStore(events: [event(startOffset: 1500)])
        let slot = CalendarSlot(provider: fake)
        await slot.refresh(now: now)
        #expect(slot.scene(snapshot: snapshot, now: now)?.valueText == "25分")

        fake.throwNext(CalendarError.denied)
        await slot.refresh(now: now.addingTimeInterval(60))   // 下一轮兜底重算
        #expect(slot.scene(snapshot: snapshot, now: now.addingTimeInterval(60)) == nil)
    }

    @Test func slotKeepsStaleValueOnTransientFailure() async {
        // 非 denied 的瞬时失败 → 保留旧值（迟到好过闪烁，同插件槽陈旧策略）
        let fake = FakeEventStore(events: [event(startOffset: 1560)])   // +60s 后距开始仍 1500s
        let slot = CalendarSlot(provider: fake)
        await slot.refresh(now: now)
        fake.throwNext(CalendarError.unavailable("服务未就绪"))
        let later = now.addingTimeInterval(60)
        await slot.refresh(now: later)
        #expect(slot.scene(snapshot: snapshot, now: later)?.valueText == "25分")
    }

    @Test func slotBackgroundRefreshFillsCacheEventually() async throws {
        // scene() 是同步协议：调度后台拉取 + 立即返回缓存（PluginSlot 同款形态）
        let anchor = Date()
        let fake = FakeEventStore(events: [
            CalendarEvent(
                id: "bg",
                title: "背景拉取",
                startDate: anchor.addingTimeInterval(5400),   // 90 分 → "1.5时"（轮询漂移 ±3 分内不变）
                endDate: anchor.addingTimeInterval(7200),
                isAllDay: false
            ),
        ])
        let slot = CalendarSlot(provider: fake)
        var scene: SlotScene? = nil
        for _ in 0..<100 {   // 50ms × 100 = 5s 上限（CI 慢机容忍），后台拉取通常毫秒级
            scene = slot.scene(snapshot: snapshot, now: anchor)
            if scene?.valueText == "1.5时" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(scene == SlotScene(symbol: "calendar", valueText: "1.5时"))
    }

    @Test func providerReceivesVisibilityWindow() async {
        // 拉取窗口 = CAL-01 的 24h（参数不被中途篡改）
        let fake = FakeEventStore(events: [])
        let slot = CalendarSlot(provider: fake)
        await slot.refresh(now: now)
        #expect(fake.recordedWindow() == EventTimeline.visibilityWindow)
    }
}

// MARK: - 测试假件

/// 假事件源：桩数据可翻转（成功 → 抛错），锁保护全部可变态
private final class FakeEventStore: EventStoreReading, @unchecked Sendable {
    private let lock = NSLock()
    private var stub: [CalendarEvent]
    private var pendingError: Error?
    private var recordedWindowValue: TimeInterval?

    init(events: [CalendarEvent]) {
        self.stub = events
    }

    func throwNext(_ error: Error) {
        lock.withLock { pendingError = error }
    }

    func recordedWindow() -> TimeInterval? {
        lock.withLock { recordedWindowValue }
    }

    func upcomingEvents(window: TimeInterval) async throws -> [CalendarEvent] {
        try lock.withLock {
            recordedWindowValue = window
            if let pendingError {
                self.pendingError = nil
                throw pendingError
            }
            return stub
        }
    }
}

/// 静音控制器假件：T-041b 注入真实 CoreAudio 实现前的测试替身
private final class FakeMuteController: MuteControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    var isInputMuted: Bool { lock.withLock { muted } }

    func setInputMuted(_ value: Bool) throws {
        lock.withLock { muted = value }
    }
}
