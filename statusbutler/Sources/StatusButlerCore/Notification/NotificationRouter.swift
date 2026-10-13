import Foundation
import UserNotifications

// T-215 通知系统接线（E11·TF-30 温度警报 / E13 电池养护提醒 / E18 体检每周提醒）：
// UNUserNotificationCenter 封装（授权流 + 发送）+ 规则化频率限制。
// 全部默认关——启用子集由设置层（开关默认关）裁决后注入 rules，本路由不自带
// 任何默认启用的规则（AGENTS 隐私权限最小化：不装通知中心就不发通知）。

// MARK: - 通知投递协议（注入；真实现包 UNUserNotificationCenter，测试记调用）

public protocol UserNotifying: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// 请求授权；denied 后系统不重弹，如实返回 false（用户去系统设置改，App 不纠缠）
    func requestAuthorization() async -> Bool
    func deliver(title: String, body: String) async
}

/// UNUserNotificationCenter 真实现适配。只在主线组合根构造——测试注入假实现，
/// CI/单测进程不触碰 UNUserNotificationCenter.current()（无 bundle 的进程里
/// 它的行为未定义，这是把它隔离在本类型里的原因）
public struct SystemUserNotifier: UserNotifying {
    public init() {}

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    public func requestAuthorization() async -> Bool {
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return granted == true
    }

    public func deliver(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "statusbutler.alert.\(UUID().uuidString)",
            content: content,
            trigger: nil  // 立即投递；频率限制在 AlertRateLimiter，不在触发器
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 警报规则（threshold / duration / cooldown）

/// 一条警报规则：指标越阈 + 持续时长 + 冷却窗口三要素
public struct AlertRule: Equatable, Sendable, Identifiable {
    /// 判定指标与越阈方向（温度 > 阈值；电量/体检分 < 阈值）
    public enum Metric: Equatable, Sendable {
        case temperatureMaxCelsius
        case batteryPercent
        case healthScore
    }

    public let id: String
    public let metric: Metric
    public let threshold: Double
    /// 持续时长：条件须连续成立满该时长才触发（0 = 首见即触发，用于缓变指标）
    public let sustain: TimeInterval
    /// 冷却窗口：两次通知的最小间隔（频率限制的唯一闸口）
    public let cooldown: TimeInterval
    public let title: String
    public let body: String

    public init(
        id: String,
        metric: AlertRule.Metric,
        threshold: Double,
        sustain: TimeInterval,
        cooldown: TimeInterval,
        title: String,
        body: String
    ) {
        self.id = id
        self.metric = metric
        self.threshold = threshold
        self.sustain = sustain
        self.cooldown = cooldown
        self.title = title
        self.body = body
    }
}

/// 规则表（主线接线清单：设置页开关全部默认关，启用后把子集注入 NotificationRouter）
public enum AlertRules {
    /// TF-30 温度警报：最高温 >90°C 持续 60s → 通知；冷却 10 分钟
    /// （瞬时尖峰（编译 burst）不该吵人，持续过热才是警报）
    public static let temperatureHigh = AlertRule(
        id: "temperatureHigh",
        metric: .temperatureMaxCelsius,
        threshold: 90,
        sustain: 60,
        cooldown: 600,
        title: "温度警报",
        body: "最高温度已超过 90°C 持续一分钟，请检查负载与散热"
    )
    /// E13 电池养护提醒：<20% → 通知；冷却 30 分钟
    /// （低电期间每轮采样都越阈，没有冷却会刷屏）
    public static let batteryLow = AlertRule(
        id: "batteryLow",
        metric: .batteryPercent,
        threshold: 20,
        sustain: 0,
        cooldown: 1800,
        title: "电池电量低",
        body: "电量已低于 20%，建议接入电源"
    )
    /// E18 体检每周提醒：分数 <60 → 每周最多一次
    public static let healthPoor = AlertRule(
        id: "healthPoor",
        metric: .healthScore,
        threshold: 60,
        sustain: 0,
        cooldown: 7 * 24 * 3600,
        title: "体检提醒",
        body: "系统体检得分低于 60，建议尽快处理未通过项"
    )

    public static let all: [AlertRule] = [temperatureHigh, batteryLow, healthPoor]
}

// MARK: - 采样与频率限制判定（纯函数）

/// 一次采样的三路输入；缺测域不参与任何判定（不猜）
public struct AlertSample: Equatable, Sendable {
    public var maxCelsius: Double?
    public var batteryPercent: Int?
    public var healthScore: Int?

    public init(maxCelsius: Double? = nil, batteryPercent: Int? = nil, healthScore: Int? = nil) {
        self.maxCelsius = maxCelsius
        self.batteryPercent = batteryPercent
        self.healthScore = healthScore
    }
}

/// 单规则的频率限制状态（显式值传递，决策函数保持纯）
public struct AlertGateState: Equatable, Sendable {
    /// 条件首次成立时刻；条件中断（未越阈或缺测）即清除——sustain 从零重计
    public var conditionSince: Date?
    public var lastNotifiedAt: Date?

    public init(conditionSince: Date? = nil, lastNotifiedAt: Date? = nil) {
        self.conditionSince = conditionSince
        self.lastNotifiedAt = lastNotifiedAt
    }
}

public enum AlertRateLimiter {
    /// 指标越阈判定：nil = 该规则域缺测（不判定）；true = 越阈；false = 未越
    public static func isViolating(_ rule: AlertRule, sample: AlertSample) -> Bool? {
        switch rule.metric {
        case .temperatureMaxCelsius:
            return sample.maxCelsius.map { $0 > rule.threshold }
        case .batteryPercent:
            return sample.batteryPercent.map { Double($0) < rule.threshold }
        case .healthScore:
            return sample.healthScore.map { Double($0) < rule.threshold }
        }
    }

    /// 单规则决策（纯函数 + inout 状态；时钟由调用方注入，可测）：
    /// sustain 闸（首见记时刻、断见清零、满时长放行）→ cooldown 闸
    /// （距上次通知满冷却窗口才放行）。放行即回写 lastNotifiedAt 并返回 true
    @discardableResult
    public static func decide(
        rule: AlertRule,
        sample: AlertSample,
        state: inout AlertGateState,
        now: Date
    ) -> Bool {
        guard let violating = isViolating(rule, sample: sample) else {
            state.conditionSince = nil  // 缺测视为条件中断（保守：不累计 sustain）
            return false
        }
        guard violating else {
            state.conditionSince = nil
            return false
        }
        if state.conditionSince == nil {
            state.conditionSince = now
            if rule.sustain > 0 { return false }  // 首见且需持续 → 等下一轮采样计时
        } else if now.timeIntervalSince(state.conditionSince!) < rule.sustain {
            return false  // 持续中，未满时长
        }
        if let last = state.lastNotifiedAt, now.timeIntervalSince(last) < rule.cooldown {
            return false  // 冷却窗口内（窗口边界 == cooldown 时放行）
        }
        state.lastNotifiedAt = now
        return true
    }
}

// MARK: - 路由器（UNUserNotificationCenter 封装）

/// 通知路由：授权流 + 规则判定 + 投递。@MainActor 与 Store/控制器同纪律；
/// 喂样节奏由主线决定（弹层可见期/采样回调），process 可任意频率调用——
/// 频率限制在 decide 内消化，调用方不需要自行节流
@MainActor
public final class NotificationRouter: ObservableObject {
    private let rules: [AlertRule]
    private let notifier: (any UserNotifying)?
    private let clock: () -> Date
    private var gateStates: [String: AlertGateState] = [:]

    /// nil = 从未请求过授权；false = 被拒（去系统设置是唯一出路）
    @Published public private(set) var isAuthorized: Bool?
    /// 最近一次 process 实际判定放行的规则 id（授权被拒时也会更新——
    /// 状态机照常运转，授权恢复后即可恢复投递）
    @Published public private(set) var lastFiredRuleIDs: [String] = []

    /// notifier 不注入 = 只判定不投递（设置开关全关时的形态，规则照跑不留死角）
    public init(
        rules: [AlertRule],
        notifier: (any UserNotifying)? = nil,
        clock: (() -> Date)? = nil
    ) {
        self.rules = rules
        self.notifier = notifier
        self.clock = clock ?? { Date() }
    }

    /// 授权流（首次启用通知的设置页触发）。真实现走 requestAuthorization；
    /// 缺测判定模式下恒 false（无投递面即无需授权）
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard let notifier else {
            isAuthorized = false
            return false
        }
        let granted = await notifier.requestAuthorization()
        isAuthorized = granted
        return granted
    }

    /// 喂样判定 + 投递。返回本次放行的规则 id（授权被拒/未注入投递面时
    /// 返回值照常，只是不实际发通知）
    @discardableResult
    public func process(_ sample: AlertSample, now: Date? = nil) async -> [String] {
        let now = now ?? clock()
        var firedRules: [AlertRule] = []
        for rule in rules {
            var state = gateStates[rule.id] ?? AlertGateState()
            if AlertRateLimiter.decide(rule: rule, sample: sample, state: &state, now: now) {
                firedRules.append(rule)
            }
            gateStates[rule.id] = state
        }
        lastFiredRuleIDs = firedRules.map(\.id)
        if !firedRules.isEmpty, await isDeliveryAllowed() {
            for rule in firedRules {
                await notifier?.deliver(title: rule.title, body: rule.body)
            }
        }
        return firedRules.map(\.id)
    }

    private func isDeliveryAllowed() async -> Bool {
        guard let notifier else { return false }
        let status = await notifier.authorizationStatus()
        return status == .authorized || status == .provisional
    }
}
