import Foundation

// T-211 会议条（E15·MTG-02）：弹层顶部"会议条"的数据投影与映射。
// 会议条是面板旁路数据（架构铁律 3：画不进图标的不进 StatusSnapshot）；
// MTG-03 隐私：默认只显"会议中"不显事件标题——标题永不进入本类型（编译期不可泄漏），
// 与 CalendarSlot.scene 的纪律同源。

// MARK: - 会议条状态

/// 会议条一屏状态（provider 注入；nil = 无进行中会议，整条隐藏）
public struct MeetingBarState: Equatable, Sendable {
    /// 事件 id（同一会议跨轮询保持稳定）
    public let eventID: String
    /// 剩余时长简写（与日程倒数同一套规格："25分" / "1.5时"）
    public let remainingText: String
    /// 一键入会链接（MeetingLinkDetector 解析产物原样透传，MTG-01）
    public let joinURL: URL
    /// 输入静音态（nil = 静音控制器未接线，静音按钮隐藏）
    public let isInputMuted: Bool?

    public init(eventID: String, remainingText: String, joinURL: URL, isInputMuted: Bool?) {
        self.eventID = eventID
        self.remainingText = remainingText
        self.joinURL = joinURL
        self.isInputMuted = isInputMuted
    }
}

// MARK: - 注入类型（主线接线清单见 PanelViewModel.init 各参数注记）

/// 会议条 provider：主线在弹层可见期旁路轮询。闭包内以当前时刻查
/// `EventTimeline.inProgressEvents` + 链接判定（MeetingCenter 同口径），
/// 时间轴缓存新鲜度归 provider 侧（EventKit 取数是异步，不进同步闭包）
public typealias MeetingBarStateProvider = @Sendable () -> MeetingBarState?

/// 会议中静音切换（MTG-02：系统输入静音，公开 CoreAudio）。
/// AudioInputMonitor 只有读路径，写路径是 MuteControlling（T-041b）——
/// VM 不直连引擎，经闭包注入；返回切换后静音态，nil = 失败/不在会中
public typealias MeetingMuteToggler = @Sendable () -> Bool?

// MARK: - 映射（纯函数）

public enum MeetingBarMapping {
    /// EventTimeline → 会议条状态（纯函数，测试喂固定事件钉死判定）：
    /// 只收"进行中 + 带入会链接"的非全天事件（inMeeting 判定与
    /// MeetingCenter.currentMeeting 同口径：多场重叠取最早开始的那场）
    public static func state(from timeline: EventTimeline, now: Date, isInputMuted: Bool?) -> MeetingBarState? {
        guard
            let meeting = timeline.inProgressEvents(now: now).first(where: { $0.meetingURL != nil }),
            let joinURL = meeting.meetingURL
        else { return nil }
        return MeetingBarState(
            eventID: meeting.id,
            remainingText: EventTimeline.durationText(seconds: meeting.endDate.timeIntervalSince(now)),
            joinURL: joinURL,
            isInputMuted: isInputMuted
        )
    }
}
