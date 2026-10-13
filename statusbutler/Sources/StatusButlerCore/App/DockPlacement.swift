import AppKit

/// Dock 在屏幕边的位置（A2·S2 reopen 判定的几何输入）：系统不直接暴露 Dock 朝向，
/// 但 Dock 是唯一能横向压缩 visibleFrame 的常驻物（菜单栏只压顶部）——由两框差推断。
/// 纯几何、无系统状态读取，headless 可全测
public enum DockPlacement: Equatable, Sendable {
    case bottom
    case left
    case right

    public static func resolve(screenFrame: NSRect, visibleFrame: NSRect) -> DockPlacement {
        if visibleFrame.minX > screenFrame.minX { return .left }
        if visibleFrame.maxX < screenFrame.maxX { return .right }
        return .bottom
    }

    /// 屏幕点是否落在 Dock 沿边的条带内。
    /// Dock 可见时条带 = Dock 从屏幕扣走的区域；自动隐藏时 visibleFrame 填满屏幕，
    /// 边沿容差是唯一可用信号（点击 Dock 会先令其短暂浮现，指针必落容差带内）
    public func containsPointer(
        _ point: NSPoint,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        collapsedTolerance: CGFloat = 120
    ) -> Bool {
        switch self {
        case .bottom:
            let strip = visibleFrame.minY - screenFrame.minY
            let limit = strip > 4 ? visibleFrame.minY : screenFrame.minY + collapsedTolerance
            return point.y <= limit
        case .left:
            let strip = visibleFrame.minX - screenFrame.minX
            let limit = strip > 4 ? visibleFrame.minX : screenFrame.minX + collapsedTolerance
            return point.x <= limit
        case .right:
            let strip = screenFrame.maxX - visibleFrame.maxX
            let limit = strip > 4 ? visibleFrame.maxX : screenFrame.maxX - collapsedTolerance
            return point.x >= limit
        }
    }
}
