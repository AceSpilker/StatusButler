import AppKit
import ApplicationServices
import Foundation

// MARK: - AX 读取桥：图标级枚举（MB-01，A14-ε 实装 T-053b 预留的注入点）
// 路线（T-053a 调研的落地）：SystemUIServer 是所有状态栏 item 的宿主进程，
// 本进程用公开的 Accessibility API 读它菜单栏 AX 树的直接子项——不注入、不钩子。
// AX 是公开 API，但读的是 SystemUIServer 私有视图结构的语义投影：树形/属性名
// 随大版本漂移（本机 macOS 26 实测 AXMenuBar/AXExtrasMenuBar 可拒绝读取——
// kAXErrorCannotComplete），所以环境性读不到是设计内的失败形态：返回 nil →
// 枚举器亮 .axUnavailable（fail-visible），绝不崩、不伪装有数据。
// 版本脆弱性由 VersionGate 白名单钉死（MB-04），授权前置由本层自查。

/// AX 树拍平后的值语义行（跨隔离可发送；AXUIElement 本体绝不离开 @MainActor）
public struct MenubarAXRow: Equatable, Sendable {
    /// 稳定标识首选（App 挂在 item 上的 AXIdentifier，常为 bundle id 类字符串）
    public var identifier: String?
    /// 辅助文本（多为图标的人类可读名，如 "蓝牙"）；identifier 缺席时的回退标识
    public var descriptionText: String?
    /// 宽度。0 = 已隐藏（"宽度置 0" 是本模块自己的写语义，见 AXMenubarApplier）
    public var width: CGFloat

    public init(identifier: String?, descriptionText: String?, width: CGFloat) {
        self.identifier = identifier
        self.descriptionText = descriptionText
        self.width = width
    }
}

public struct MenubarAXSnapshot: Equatable, Sendable {
    public var rows: [MenubarAXRow]

    public init(rows: [MenubarAXRow]) {
        self.rows = rows
    }
}

/// AX 读取门面（测试注入假工厂）：把 ApplicationServices C API 折叠成两个语义动作，
/// 假实现只需给布尔/快照即可驱动枚举器全分支。
@MainActor
public protocol MenubarAXAccessing: Sendable {
    /// 辅助功能授权态。只读不弹引导——授权引导是设置页的 UX，不属采集路径
    func isProcessTrusted() -> Bool
    /// SystemUIServer 菜单栏全部直接子项拍平；SystemUIServer 不在/树读不出 → nil
    func snapshotSystemMenuBar() -> MenubarAXSnapshot?
}

/// 真实现。菜单栏入口按优先级试两条属性：AXMenuBar（AppKit 标准入口）→
/// AXExtrasMenuBar（刘海屏机型第三方 item 的宿主；无 Swift 常量，字符串字面量钉死）。
@MainActor
public struct SystemUIServerAXAccessing: MenubarAXAccessing {
    public init() {}

    public func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func snapshotSystemMenuBar() -> MenubarAXSnapshot? {
        guard let pid = MenubarAXSupport.systemUIServerPID() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)  // 采集路径短超时：SystemUIServer 卡死不拖垮调用方
        let barElements = MenubarAXSupport.menuBarElements(of: appElement)
        guard !barElements.isEmpty else { return nil }

        var rows: [MenubarAXRow] = []
        for bar in barElements {
            for item in MenubarAXSupport.children(of: bar) {
                rows.append(
                    MenubarAXRow(
                        identifier: MenubarAXSupport.string(item, kAXIdentifierAttribute),
                        descriptionText: MenubarAXSupport.string(item, kAXDescriptionAttribute),
                        width: MenubarAXSupport.size(item)?.width ?? 0
                    )
                )
            }
        }
        return MenubarAXSnapshot(rows: rows)
    }
}

/// AX C API 小工具（读侧/写侧共用）。CFTypeRef → 具体类型必须走 CFGetTypeID 比对：
/// Swift 6 把对 CF 类型的条件 downcast 视为恒真错误，盲 cast 会在错误的 CF 类型上崩。
enum MenubarAXSupport {
    /// SystemUIServer pid。NSWorkspace 拿不到（系统进程未起/极端沙盒）→ nil
    static func systemUIServerPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver")
            .first?.processIdentifier
    }

    /// 应用元素 → 全部菜单栏元素（多屏多条）。两条入口属性逐条试读，全失败返回空。
    static func menuBarElements(of appElement: AXUIElement) -> [AXUIElement] {
        var bars: [AXUIElement] = []
        for attribute in [kAXMenuBarAttribute, "AXExtrasMenuBar"] {
            guard let raw = attributeValue(appElement, attribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { continue }
            bars.append(unsafeDowncast(raw as AnyObject, to: AXUIElement.self))
        }
        return bars
    }

    /// 元素 → 直接子项（超过 128 个子项的菜单栏不存在；截断保护防异常树拖垮内存）
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, 128, &values) == .success
        else { return [] }
        return values as? [AXUIElement] ?? []
    }

    static func attributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        attributeValue(element, attribute) as? String
    }

    /// AXSize 读值。非 AXValue（残缺树）返回 nil，调用方按"宽度未知=0"兜底
    static func size(_ element: AXUIElement) -> CGSize? {
        guard let raw = attributeValue(element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize()
        let value = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}

// MARK: - 图标级枚举器（MenubarItemEnumerating 实现）
@MainActor
public final class StatusItemEnumerator: MenubarItemEnumerating {
    /// fail-visible 状态：调用方（设置页/引擎装配点）据此引导授权或诚实降级，
    /// 而不是对着空列表猜"是没图标还是坏了"
    public enum EnumerationStatus: Equatable, Sendable {
        case ok
        case needsAccessibilityPermission
        /// 已授权但树读不出：SystemUIServer 不在，或当前 macOS 拒绝菜单栏属性读取
        /// （本机 macOS 26 实测即此形态——MB-04 版本白名单内的已知限制，fail-visible 上浮）
        case axUnavailable
    }

    public private(set) var lastStatus: EnumerationStatus = .ok

    private let ax: any MenubarAXAccessing

    public init(ax: any MenubarAXAccessing = SystemUIServerAXAccessing()) {
        self.ax = ax
    }

    public func enumerateItems() -> [MenubarItem] {
        guard ax.isProcessTrusted() else {
            lastStatus = .needsAccessibilityPermission
            return []
        }
        guard let snapshot = ax.snapshotSystemMenuBar() else {
            lastStatus = .axUnavailable
            return []
        }
        lastStatus = .ok
        return Self.items(from: snapshot)
    }

    /// 纯映射（可单测）：AX 行 → MenubarItem。identifier 三级回退
    /// （AXIdentifier > AXDescription > ax.<序号>），保证非空可规则匹配（MenubarItem 契约）。
    /// 所属 App 名取描述文本近似——AX 路线拿不到 item 真实的归属进程（宿主都是
    /// SystemUIServer），这是 MB-01"清单显示所属 App"在公开 API 下的诚实上限。
    nonisolated static func items(from snapshot: MenubarAXSnapshot) -> [MenubarItem] {
        snapshot.rows.enumerated().map { index, row in
            MenubarItem(
                ownerAppName: row.descriptionText ?? "状态栏项",
                title: row.descriptionText,
                identifier: row.identifier ?? row.descriptionText ?? "ax.\(index)",
                isVisible: row.width > 0
            )
        }
    }
}
