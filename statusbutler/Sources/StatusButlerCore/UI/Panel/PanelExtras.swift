import Foundation
import os

// MARK: - 动作行渲染数据（A3·E2 动作中心面板行，A14-β）

/// availability → 徽标文案/灰显的展示侧映射（纯函数）。AC-02 诚实分级：
/// 灰显只给"本机不支持"；需权限/深链保持可点——点击走注入执行器引导/跳系统，由执行侧裁决
public enum ActionStripStyling {
    public static func badgeText(for availability: ActionAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .needsPermission(let permission): return "需\(permission)"
        case .unavailableOnSystem: return "本机不支持"
        case .deepLinkOnly: return "跳系统"
        }
    }

    public static func isDisabled(for availability: ActionAvailability) -> Bool {
        availability == .unavailableOnSystem
    }
}

// MARK: - 体检报告展示档位（A3·E18，A14-β）

/// 分数色档（≥85 优 / 60-84 良 / <60 差）。分数本体在 HealthReport.score（纯函数已测），
/// 这里只补展示档位映射——颜色落在 View 层，档位保持纯值可测
public enum HealthScoreTier: Equatable, Sendable {
    case good
    case fair
    case poor

    public static func tier(forScore score: Int) -> HealthScoreTier {
        if score >= 85 { return .good }
        if score >= 60 { return .fair }
        return .poor
    }
}

// MARK: - 面板旁路数据 provider（主线喂，nil 即隐藏——数据新鲜度归 provider 侧）

public typealias WeatherTextProvider = @Sendable () -> String?
public typealias CalendarTextProvider = @Sendable () -> String?
public typealias HealthReportProvider = @Sendable () -> HealthReport?

// MARK: - 槽位轮换（footer，A14-β）

/// 弹层 footer 槽位循环协议（注入）。真实实现归主线（SettingsStore 持久化 +
/// SlotRegistry 源表），Panel 只消费"当前显示名/切下一个"两个动作
public protocol SlotCycling: Sendable {
    func currentLabel() -> String
    @discardableResult
    func cycle() -> String
}

/// 测试/预览用静态轮换器。class + 锁：protocol 要求 let 存储存在性时 struct 的
/// 值语义会在每次调用后丢失游标，轮换必须引用语义
public final class StaticSlotCycler: SlotCycling, @unchecked Sendable {
    // @unchecked Sendable 论证：index 仅在 OSAllocatedUnfairLock 内读写，labels 初始化后只读
    private let labels: [String]
    private let index = OSAllocatedUnfairLock(initialState: 0)

    public init(labels: [String]) {
        self.labels = labels
    }

    public func currentLabel() -> String {
        index.withLock { labels.isEmpty ? "" : labels[$0] }
    }

    @discardableResult
    public func cycle() -> String {
        index.withLock { current in
            guard !labels.isEmpty else { return "" }
            current = (current + 1) % labels.count
            return labels[current]
        }
    }
}
