import Foundation

// T-041（A8·CAL-01~04 / A12·E15·MTG-02）：日程倒数槽位 + 会议中判定。
// SlotSource.scene() 是同步协议（E1），而 EventKit 取数是异步——沿用 PluginSlot
// 的"到期判定 + 后台触发 + 立即返回缓存"形态：渲染线程零 IO 零等待。
// 注册进 SlotRegistry 由集成方完成（本文件不触碰 SlotSystem.swift，
// registry 里 "calendarCountdown" 目前由 PendingSlot 占位）。

/// 日历倒数槽位源：下一件事倒计时（CAL-01）。
/// 刷新节奏 = CAL-04 的 60 秒兜底；EKEventStore 变更通知由宿主接线
/// （T-041b），本槽位只负责"有人看才拉"（能效铁律）。
public struct CalendarSlot: SlotSource {
    public let id = "calendarCountdown"

    /// CAL-04：变更通知之外的 60 秒兜底重算
    public static let refreshInterval: TimeInterval = 60

    private let provider: any EventStoreReading
    private let window: TimeInterval
    private let cache: EventCache

    public init(provider: any EventStoreReading, window: TimeInterval = EventTimeline.visibilityWindow) {
        self.provider = provider
        self.window = window
        self.cache = EventCache()
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        // 有人看才运行：渲染拉取场景时才调度后台刷新（in-flight/新鲜期内直接吃缓存）
        if cache.shouldRefresh(hint: Self.refreshInterval, now: now), cache.markRefreshStarted(now: now) {
            Task.detached(priority: .utility) {
                await self.refresh(now: Date())
            }
        }
        return Self.scene(from: EventTimeline(events: cache.events), now: now)
    }

    /// 拉取并写缓存——scene() 的后台路径本体；公开给宿主强制刷新
    /// （收到 EKEventStoreChanged 时）与测试直接 await（确定性，免轮询）
    public func refresh(now: Date) async {
        do {
            let events = try await provider.upcomingEvents(window: window)
            cache.apply(events: events, now: now)
        } catch {
            cache.applyFetchFailed(error: error, now: now)
        }
    }

    /// 场景决策（纯函数，钉死测试）：
    /// 无下一件事（空日程/缓存尚空/授权被拒清空）→ nil（注册表保留占位，E1 协议语义）。
    /// CAL-03 隐私红线钉死：SlotScene 永不携带事件标题——菜单栏/截图/锁屏都是
    /// 公开面，槽位只有倒计时数字；标题只允许出现在面板层（默认还以"忙碌"替代）。
    /// 此函数体内根本不接触 next.title，编译期即不可泄漏。
    public static func scene(from timeline: EventTimeline, now: Date) -> SlotScene? {
        guard let next = timeline.nextEvent(now: now) else { return nil }
        return SlotScene(
            symbol: "calendar",
            valueText: EventTimeline.countdownText(next: next, now: now)
        )
    }
}

/// 事件缓存：最近一次成功拉取 + 刷新调度状态。
/// 锁纪律同 PluginSlot.SceneCache：可变态全在锁内，锁内无回调无 IO
final class EventCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedEvents: [CalendarEvent] = []
    private var lastFetch: Date?
    private var inFlight = false

    var events: [CalendarEvent] { lock.withLock { cachedEvents } }

    /// 到期判定：无在途拉取、距上次发起 ≥ 80% 兜底间隔
    /// （间隔/5 宽容，避免恰好到期时空档闪烁）
    func shouldRefresh(hint: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            if inFlight { return false }
            guard let last = lastFetch else { return true }
            return now.timeIntervalSince(last) >= hint * 0.8
        }
    }

    /// 占位发起：锁内双检 inFlight，并发拉取只放行第一个
    func markRefreshStarted(now: Date) -> Bool {
        lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            lastFetch = now
            return true
        }
    }

    func apply(events: [CalendarEvent], now: Date) {
        lock.withLock {
            inFlight = false
            lastFetch = now
            cachedEvents = events
        }
    }

    /// 失败路径：被拒 → 清空缓存降级（权限没了，旧日程不该继续倒数，CAL-04）；
    /// 其他失败 → 保留旧值（迟到好过闪烁，同 PluginSlot 陈旧标注策略）
    func applyFetchFailed(error: Error, now: Date) {
        lock.withLock {
            inFlight = false
            lastFetch = now
            if case CalendarError.denied = error {
                cachedEvents = []
            }
        }
    }
}

// MARK: - 会议中模式（MTG-02）

/// 麦克风输入静音占位协议：引擎层不 import CoreAudio（红线三：权限最小化），
/// 真实实现（系统输入设备静音，公开 CoreAudio）由 T-041b 面板层注入接线
public protocol MuteControlling: Sendable {
    /// 当前输入静音态（会议条展示）
    var isInputMuted: Bool { get }
    /// 切换静音；失败上抛由面板层提示
    func setInputMuted(_ muted: Bool) throws
}

/// 会议中判定与会议条数据：当前会议 = 进行中 + 带入会链接的事件（MTG-01/02）。
/// 静音动作经注入的 MuteControlling 执行；未接线 → 动作不可用（面板禁用按钮）
public struct MeetingCenter: Sendable {
    private let timeline: EventTimeline
    private let muteController: (any MuteControlling)?

    public init(events: [CalendarEvent], muteController: (any MuteControlling)? = nil) {
        self.timeline = EventTimeline(events: events)
        self.muteController = muteController
    }

    public var events: [CalendarEvent] { timeline.events }

    /// 当前会议：进行中且解析出入会链接；多场重叠取最早开始的那场
    public func currentMeeting(now: Date) -> CalendarEvent? {
        timeline.inProgressEvents(now: now).first { $0.meetingURL != nil }
    }

    public func inMeeting(now: Date) -> Bool {
        currentMeeting(now: now) != nil
    }

    /// 会议条"剩余时长"（MTG-02）：与倒计时同一套简写规格；
    /// MTG-03：文本不含标题，会议条默认只说"会议中"
    public func remainingText(now: Date) -> String? {
        guard let meeting = currentMeeting(now: now) else { return nil }
        return EventTimeline.durationText(seconds: meeting.endDate.timeIntervalSince(now))
    }

    /// 静音切换（MTG-02 占位动作）：返回切换后的静音态。
    /// 不在会中或控制器未接线 → nil（调用方据此禁用入口）
    public func toggleMute(now: Date) throws -> Bool? {
        guard inMeeting(now: now), let muteController else { return nil }
        let target = !muteController.isInputMuted
        try muteController.setInputMuted(target)
        return target
    }
}
