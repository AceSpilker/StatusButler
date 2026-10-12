// 图标位置（A2·S2）：决定激活策略与两端渲染开关
public enum AppIconPlacement: String, Sendable, CaseIterable {
    case menuBarOnly
    case dockOnly
    case both

    public var showsMenuBarIcon: Bool { self != .dockOnly }
    public var showsDockIcon: Bool { self != .menuBarOnly }

    /// LSUIElement(accessor) ↔ Regular 的映射
    public var usesRegularPolicy: Bool { showsDockIcon }
}
