import Foundation

// T-041（A8·CAL-01~03 / A12·E15·MTG-01/03）：日程倒数 + 会议助手的纯数据与逻辑层。
// 纪律：本文件零 IO、零 EventKit（EventKit 只允许出现在 EventStoreReading 的 Live 实现里），
// 判定全部函数化——CI 无日历权限也能全量钉死行为。

/// 日历事件最小投影：只取槽位/时间轴/会议判定需要的字段
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    /// 全天事件不参与倒数/忙碌/会议判定（CAL-01 默认口径，可配项未来再开）
    public var isAllDay: Bool
    /// 入会链接（标题/备注本地正则解析，MTG-03 不上传）；nil = 普通事件
    public var meetingURL: URL?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        meetingURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.meetingURL = meetingURL
    }
}

// MARK: - 入会链接检测（MTG-01 规则表）

/// 纯本地正则规则表：每条规则 = 一家会议服务的"官方入会形态"指纹
/// （scheme + host + 入会路径锚点）。host 全部锚定服务域，
/// "evil.com/zoom.us/j/1" 这类把服务域藏在路径里的仿冒不命中。
/// 正则逐次编译：检测频次极低（每次拉取 × 每个事件），不值得引入
/// static let 的 Sendable 论证负担。
public enum MeetingLinkDetector {
    /// URL 尾段 ASCII 白名单（RFC 3986 合法字符）：
    /// \S 会把中文/全角标点一起吞进链接，\w 在 ICU 里又是 Unicode 语义（中日韩全算），
    /// 都不能用——显式 ASCII 集合让链接自然止于中文标点/文字之前
    private static let urlTail = "[0-9A-Za-z._~:/?#\\[\\]@!$&'()*+,;=%-]"

    /// 规则优先级 = 表序（Zoom 最常见在前）；大小写不敏感（HTTPS:// 同样认）
    private static let patterns: [String] = [
        // Zoom 网页入会：企业子域（us05web 等）+ /j/<会议号>；?pwd= 入会密码保留
        #"https?://(?:[a-z0-9-]+\.)*zoom\.us/j/\d+(?:[?#]\#(urlTail)+)?"#,
        // Zoom 客户端深链：zoom://（规格钉死）与 zoommtg://（客户端实际注册的 scheme）一并覆盖
        #"zoom(?:mtg)?://\#(urlTail)+"#,
        // Google Meet：meet.google.com/<三段码>
        #"https?://meet\.google\.com/[a-z0-9-]+(?:[?#]\#(urlTail)+)?"#,
        // Microsoft Teams：teams.microsoft.com/l/ 入会深链（meetup-join 长 URL 整段收）
        #"https?://teams\.microsoft\.com/l/\#(urlTail)+"#,
        // 腾讯会议网页入会：meeting.tencent.com/dm/<码>（www. 等子域容忍，路径含斜杠）
        #"https?://(?:[a-z0-9-]+\.)*meeting\.tencent\.com/\#(urlTail)+"#,
        // 腾讯会议客户端深链：官方 scheme 为 wemeet
        #"wemeet://\#(urlTail)+"#,
        // 飞书/Lark 入会：vc.feishu.cn/j/<码>（国内）/ vc.larksuite.com/j/<码>（海外）
        #"https?://vc\.(?:feishu\.cn|larksuite\.com)/j/\#(urlTail)+"#,
    ]

    /// \S+ 会把句尾收尾标点一起抓进来（链接后紧跟中文逗号/右括号很常见），
    /// 这些字符不是合法 URL 尾部，统一剥掉
    private static let trailingPunctuation: Set<Character> = [
        ")", ".", ",", ";", ">", "\"", "'",
        "）", "，", "。", "；", "」", "』", "》",
    ]

    /// 标题优先（用户可见处最可信），备注兜底；nil = 无入会链接
    public static func meetingURL(from title: String, notes: String?) -> URL? {
        for text in [title, notes].compactMap({ $0 }) where !text.isEmpty {
            for raw in patterns {
                guard
                    let regex = try? NSRegularExpression(pattern: raw, options: [.caseInsensitive]),
                    let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                    let range = Range(match.range, in: text)
                else { continue }
                return URL(string: trimTrailingPunctuation(String(text[range])))
            }
        }
        return nil
    }

    private static func trimTrailingPunctuation(_ raw: String) -> String {
        var trimmed = raw
        while let last = trimmed.last, trailingPunctuation.contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - 时间轴纯查询

/// 事件时间轴：构造即按开始时间排序，查询方永不重排
public struct EventTimeline: Equatable, Sendable {
    /// CAL-01：只统计未来 24 小时内的非全天事件
    public static let visibilityWindow: TimeInterval = 24 * 3600

    /// 按开始时间升序（同刻开始按 id 决出稳定序，快照相等性不抖动）
    public let events: [CalendarEvent]

    public init(events: [CalendarEvent]) {
        self.events = events.sorted { lhs, rhs in
            (lhs.startDate, lhs.id) < (rhs.startDate, rhs.id)
        }
    }

    /// 下一件需要倒数的事：窗口内、非全天、尚未开始。
    /// 进行中的事件不算"下一件"——它归 busyUntil/inMeeting 管；
    /// 已结束/已开始的一律跳过（过期判定）
    public func nextEvent(now: Date, window: TimeInterval = EventTimeline.visibilityWindow) -> CalendarEvent? {
        events.first { event in
            !event.isAllDay
                && event.startDate > now
                && event.startDate.timeIntervalSince(now) <= window
        }
    }

    /// 进行中（跨 now）的非全天事件——忙碌判定与会议条共用的数据底座
    public func inProgressEvents(now: Date) -> [CalendarEvent] {
        events.filter { event in
            !event.isAllDay && event.startDate <= now && now < event.endDate
        }
    }

    /// 忙到几点：进行中事件（多场重叠取最晚结束）的结束时刻；
    /// 空闲 → nil。全天事件不制造"忙碌"（与 CAL-01 不倒数同口径）
    public func busyUntil(now: Date) -> Date? {
        inProgressEvents(now: now).map(\.endDate).max()
    }

    /// 倒计时简写（CAL-01 规格钉死）：<1 小时 → "25分"；
    /// 满 1 小时 → 一位小数 "1.5时"。已开始/负值防御性归 "0分"
    /// （正常路径 nextEvent 只给未来事件，这里兜缓存陈旧的边界）
    public static func countdownText(next: CalendarEvent, now: Date) -> String {
        durationText(seconds: next.startDate.timeIntervalSince(now))
    }

    /// 时长简写共享内核：倒计时（到开始）与会议条剩余时长（到结束）同一套规格
    static func durationText(seconds: TimeInterval) -> String {
        let clamped = max(seconds, 0)
        // 分钟按半分钟向上取整（24.5 分 → "25分"）；取整后满 60 直接进时制，
        // 杜绝 "60分" 这种两制之间的孤岛值
        let minutes = (clamped / 60).rounded()
        if minutes < 60 {
            return "\(Int(minutes))分"
        }
        return String(format: "%.1f时", clamped / 3600)
    }
}
