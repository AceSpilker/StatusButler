import Foundation

// MARK: - 条目与规则模型（T-053a · A9 MB-01/02）

/// 状态栏条目。App 级扫描阶段 identifier = bundle id（拿不到时回退 pid），
/// 图标级枚举接入后 = 私有视图树里的稳定标识；规则一律按 identifier 精确匹配，
/// 让"换标识策略"的成本集中在扫描层，用户规则档案不用迁移。
public struct MenubarItem: Equatable, Sendable {
    public var ownerAppName: String
    public var title: String?
    public var identifier: String
    public var isVisible: Bool

    public init(
        ownerAppName: String,
        title: String? = nil,
        identifier: String,
        isVisible: Bool = true
    ) {
        self.ownerAppName = ownerAppName
        self.title = title
        self.identifier = identifier
        self.isVisible = isVisible
    }
}

/// 收纳规则（MB-02）。JSON 判别键 "type" 是持久化格式，改字符串等于迁移用户档案，冻结。
/// neverTouch 不携带标识：它是设置 UI 的"不管理"占位，求值上等同规则缺席；
/// 全局暂停走 TidySettings.isEnabled = false，不借用该值表达。
public enum TidyRule: Equatable, Codable, Sendable {
    /// "总是隐藏 X"
    case alwaysHide(identifier: String)
    /// "仅电池低于 N% 时显示 Y"——联动电池快照（见 TidyEngine.batteryPercent(from:)）
    case showOnlyWhen(appIdentifier: String, batteryBelow: Int)
    /// 占位：不命中任何条目
    case neverTouch

    private enum CodingKeys: String, CodingKey {
        case type, identifier, appIdentifier, batteryBelow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "alwaysHide":
            self = .alwaysHide(identifier: try c.decode(String.self, forKey: .identifier))
        case "showOnlyWhen":
            self = .showOnlyWhen(
                appIdentifier: try c.decode(String.self, forKey: .appIdentifier),
                batteryBelow: try c.decode(Int.self, forKey: .batteryBelow)
            )
        default:
            // 未知规则类型回退占位：旧档案读到未来格式（如"按时间隐藏"）不炸，
            // 且"不命中任何条目"保证升级期间零隐藏动作（fail-visible）
            self = .neverTouch
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .alwaysHide(let identifier):
            try c.encode("alwaysHide", forKey: .type)
            try c.encode(identifier, forKey: .identifier)
        case .showOnlyWhen(let appIdentifier, let batteryBelow):
            try c.encode("showOnlyWhen", forKey: .type)
            try c.encode(appIdentifier, forKey: .appIdentifier)
            try c.encode(batteryBelow, forKey: .batteryBelow)
        case .neverTouch:
            try c.encode("neverTouch", forKey: .type)
        }
    }
}

public extension TidyRule {
    /// 规则求值（纯函数）。按数组顺序首条命中即定生死——设置页的排序即优先级；
    /// 无命中 → 默认可见：缺规则时一切照旧，这是 MB-05"绝不永久吞图标"的默认方向。
    /// 电池读不到（nil）时 showOnlyWhen 按"显示"兜底：宁可多显示，不因缺数据吞图标。
    static func visibility(
        for item: MenubarItem,
        rules: [TidyRule],
        batteryPercent: Int?
    ) -> Bool {
        for rule in rules {
            switch rule {
            case .alwaysHide(let identifier):
                if identifier == item.identifier { return false }
            case .showOnlyWhen(let appIdentifier, let batteryBelow):
                guard appIdentifier == item.identifier else { continue }
                guard let batteryPercent else { return true }
                return batteryPercent < batteryBelow  // "低于"取严格小于：阈值 20 在恰好 20% 时不显示
            case .neverTouch:
                continue
            }
        }
        return true
    }
}

// MARK: - 设置模型

/// 模块开关 + 规则档案（A9 E3"高风险·可整体关闭"的落点）。
/// 默认关闭：引擎先以纯逻辑交付，开关是设置页"恢复全部并关闭本功能"的一键出口。
/// 缺键容错解码：老档案/手改 JSON 不至于炸设置加载，回默认（关、无规则）。
public struct TidySettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var rules: [TidyRule]

    public init(isEnabled: Bool = false, rules: [TidyRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        rules = try c.decodeIfPresent([TidyRule].self, forKey: .rules) ?? []
    }
}
