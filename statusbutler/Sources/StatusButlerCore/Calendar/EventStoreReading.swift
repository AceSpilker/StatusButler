import Foundation
import EventKit

// T-041（A8·CAL-04/05）：EventKit 读取抽象 + Live 实现。
// 协议化的目的：槽位/会议判定层完全不感知 EventKit，测试注入假实现
// （CI runner 无日历权限也可全量钉死行为）；授权被拒 = CalendarError.denied，
// 由调用方降级（槽位 nil + 设置引导，CAL-04：其余功能不受影响）。

public enum CalendarError: Error, Equatable, Sendable {
    /// 日历权限被拒（用户拒绝或系统限制）→ 调用方降级
    case denied
    /// 日历服务不可用/请求抛错（保留原因便于诊断，错误细节不进 UI）
    case unavailable(String)
}

/// 事件读取抽象：返回与"现在"相关的窗口内事件，按开始时间升序。
/// 窗口语义含进行中事件（开始于过去、仍未结束）——会议中判定依赖它。
public protocol EventStoreReading: Sendable {
    /// - Parameter window: 未来窗口（秒）；槽位用 24h（CAL-01）
    func upcomingEvents(window: TimeInterval) async throws -> [CalendarEvent]
}

// MARK: - Live 实现（EventKit）

/// EKEventStore 封装：只读、授权检查、谓词取数、投影到 CalendarEvent。
/// @unchecked Sendable 论证：唯一可变态 store 在 lock 内创建与读取；
/// EKEventStore 本身线程安全（EventKit 官方文档），跨 await 使用无数据竞争
public final class LiveEventStore: EventStoreReading, @unchecked Sendable {
    private let lock = NSLock()
    private var store: EKEventStore?

    public init() {}

    /// 谓词回看量：EventKit 按"事件与区间相交"取数，但不同 OS 版本对
    /// "起点在区间前"的边界行为不完全一致——回看一天兜住所有进行中长会议
    private static let inProgressLookback: TimeInterval = 24 * 3600

    public func upcomingEvents(window: TimeInterval) async throws -> [CalendarEvent] {
        let store = lock.withLock {
            if let store = self.store { return store }
            // EKEventStore() 构造昂贵（与日历守护进程同步），按 app 生命周期缓存
            let store = EKEventStore()
            self.store = store
            return store
        }
        // 每次取数前都查授权：系统设置里随时可能被用户收回，
        // 授权已定时 request 系列立即返回不弹窗，无性能代价
        guard try await Self.requestAccess(store) else {
            throw CalendarError.denied
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.inProgressLookback),
            end: now.addingTimeInterval(window),
            calendars: nil   // CAL-05：默认全部日历（iCloud/Exchange 系统层透明）
        )
        return store.events(matching: predicate).compactMap(Self.map)
    }

    /// 授权：macOS 14+ 走 requestFullAccessToEvents（macOS 无只读事件 API，
    /// iOS 专属；本实现只读不写，红线三的"最小化"落在只读用法本身），
    /// macOS 13 走旧 requestAccess(to:)
    private static func requestAccess(_ store: EKEventStore) async throws -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                throw CalendarError.unavailable(error.localizedDescription)
            }
        }
        return try await requestLegacyAccess(store)
    }

    // 编译期消警：包住废弃 API 的封装自身标注同版本 deprecated，
    // Swift 对"同版本废弃的上下文"不重复告警（macOS 26 SDK 下 build 零警告）
    @available(macOS, introduced: 13.0, deprecated: 14.0)
    private static func requestLegacyAccess(_ store: EKEventStore) async throws -> Bool {
        do {
            return try await store.requestAccess(to: .event)
        } catch {
            throw CalendarError.unavailable(error.localizedDescription)
        }
    }

    /// EKEvent → 最小投影：已取消/时间损坏（缺刻或 start>end）的事件丢弃；
    /// 入会链接在投影时解析（标题 + 备注）
    private static func map(_ event: EKEvent) -> CalendarEvent? {
        guard
            let start = event.startDate,
            let end = event.endDate,
            start <= end,
            event.status != .canceled
        else { return nil }
        let title = event.title ?? ""
        return CalendarEvent(
            id: event.eventIdentifier ?? "\(start.timeIntervalSince1970)-\(title)",
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: event.isAllDay,
            meetingURL: MeetingLinkDetector.meetingURL(from: title, notes: event.notes)
        )
    }
}
