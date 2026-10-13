// Dock 激活裁决（A2·S2 / A14 审计三·壳项）：纯函数四情形决策表，AppDelegate 只做接线。
// 参照 ../reference/status-trio 同名决策的语义（本仓库自实现，含中文注释与决策表测试）。

public enum DockActivationAction: Equatable, Sendable {
    case showPopover
    case openSettings
    case none

    /// 点击运行中 App 的 Dock 图标送达的是 reopen 事件——它承担"弹弹层"；
    /// 冷启动（含登录项拉起）在部分启动路径也会到这里，不许弹任何东西。
    /// Launchpad / Finder / Spotlight 发同一 reopen 事件，指针位置是唯一区分信号。
    static func resolve(
        isReopenEvent: Bool,
        hasDockTile: Bool,
        isPointerInDockArea: Bool
    ) -> DockActivationAction {
        guard isReopenEvent else { return .none }
        guard hasDockTile else { return .openSettings }
        return isPointerInDockArea ? .showPopover : .openSettings
    }
}
