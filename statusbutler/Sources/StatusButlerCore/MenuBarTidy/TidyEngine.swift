import Foundation

// MARK: - 目标态计算与变更集（T-053a · A9 MB-01/02，纯函数层）
/// 引擎：扫描结果 + 规则 + 电池 → 目标可见性集合 → 变更集。零系统调用；
/// 真正的隐藏/恢复写操作在 Applier，且必须先过 VersionGate 再装配（见文末集成铁律）。
public enum TidyEngine {
    public static func plan(
        current: [MenubarItem],
        rules: [TidyRule],
        battery: Int?
    ) -> [MenubarItem] {
        current.map { item in
            var target = item
            target.isVisible = TidyRule.visibility(for: item, rules: rules, batteryPercent: battery)
            return target
        }
    }

    /// 变更集 diff：只对两端都存在的 identifier 求差。新出现的条目交给下一轮 plan，
    /// diff 绝不凭空生成"新出现即隐藏"的动作——未知项默认不碰。
    public static func changes(
        current: [MenubarItem],
        target: [MenubarItem]
    ) -> [(item: MenubarItem, to: Bool)] {
        let currentVisibility = Dictionary(
            current.map { ($0.identifier, $0.isVisible) },
            uniquingKeysWith: { first, _ in first }  // 扫描层已去重；防御脏数据取先见者
        )
        return target.compactMap { item in
            guard let wasVisible = currentVisibility[item.identifier],
                  wasVisible != item.isVisible else { return nil }
            return (item, to: item.isVisible)
        }
    }

    /// 电池联动（MB-02"仅电池低于"）：快照 → 阈值比较用的百分比；
    /// .unavailable 映射 nil，规则层对 nil 一律按"显示"兜底。
    public static func batteryPercent(from state: BatteryState) -> Int? {
        if case .battery(let level, _) = state { return level }
        return nil
    }
}

// MARK: - 版本门控（MB-04）
/// 只放行"实机回归过"的 macOS 大版本；未验证版本自动禁用并提示。
/// verified 名单由发布流程维护（T-053b 集成时落位），默认空 = fail-closed：不赌运气。
public enum VersionGate {
    public static let defaultVerifiedMajors: [Int] = []

    public static func isSupported(osMajor: Int, verified: [Int]) -> Bool {
        verified.contains(osMajor)
    }
}

// MARK: - 会话账本（MB-04/05 崩溃安全）
/// 纯内存记录"本会话我们隐藏过谁"，绝不落盘（无 UserDefaults/文件写路径）：
/// 退出即全恢复——管家退出或崩溃时内存消失，下次登录所有图标以系统默认态（可见）出现，
/// 规则重新求值后才再次隐藏。状态一旦持久化，崩溃时机不对就变成"永久吞图标"。
public actor HiddenStateTracker {
    private var hidden: Set<String> = []

    public init() {}

    public func recordHidden(_ identifier: String) {
        hidden.insert(identifier)
    }

    public func recordRestored(_ identifier: String) {
        hidden.remove(identifier)
    }

    public func currentlyHidden() -> Set<String> {
        hidden
    }

    /// 取走全部待恢复项并清空（"恢复全部并关闭本功能"/退出路径用）
    public func restoreAll() -> Set<String> {
        defer { hidden.removeAll() }
        return hidden
    }
}

// MARK: - 执行层契约（stub + 集成建议）
/// 真实现（T-053b）的写路径契约。集成铁律：
/// 1) 仅在 VersionGate.isSupported 通过后装配非空实现，否则保持 Null 实现；
/// 2) 隐藏 = 私有视图树宽度置 0（MB-01），先 tracker.recordHidden 再写；
/// 3) 恢复 = 写回原宽度后再 tracker.recordRestored；停用/退出走 tracker.restoreAll()
///    先恢复全部再应用（MB-05"恢复全部并关闭本功能"的一键出口）；
/// 4) 只恢复 tracker 记录过的条目——绝不碰本会话没隐藏过的图标（防误伤系统项）；
/// 5) 写失败（AX 报错/进程退出竞态）静默记账回滚，不重试风暴。
public protocol MenubarTidyApplying: Sendable {
    func apply(changes: [(item: MenubarItem, to: Bool)]) async
}

/// 空实现：门未开/未注入时的占位，保证装配点总能成立、上层代码无分支差异。
public struct NullMenubarTidyApplier: MenubarTidyApplying {
    public init() {}

    public func apply(changes: [(item: MenubarItem, to: Bool)]) async {}
}
