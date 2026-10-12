import AppKit

/// NSPopover 壳（T-030）：自持弹层生命周期，只暴露 open/close/toggle，
/// 不触碰 StatusBarController（锚定接线归集成方，见下方集成点）。
///
/// 集成点（组合根 / StatusBarController 接线方）：
/// 1. 组合根持有强引用：`let popover = StatusPopoverController(viewModel: panelViewModel)`
///    ——本实例即弹层生命周期，实例释放弹层随之失效；
/// 2. 菜单栏按钮点击接入：`statusItem.button?.target/action` 触发处调用
///    `popover.toggle(anchorView: button)`（多屏定位由 AppKit 按 anchorView
///    所在窗口自动处理，满足 A2·S3"锚定 Popover 多屏定位正确"）；
/// 3. 可见性接线：`popover.onVisibilityChange = { [tracker] in tracker.setVisible($0) }`
///    ——与面板 SwiftUI onAppear/onDisappear 双通道汇入同一 PopoverVisibilityTracker，
///    tracker 侧 removeDuplicates 去重（.transient 收起时 SwiftUI 的 onDisappear
///    不保证即时触发，NSPopover 委托是可靠兜底）。
@MainActor
public final class StatusPopoverController: NSObject, NSPopoverDelegate {
    /// 直接暴露弹层本体：集成方需要自定义外观（箭头方向偏好、外观跟随）时可用，
    /// behavior/内容控制器已在本类配置，一般无需改动
    public let popover = NSPopover()

    private let contentController: PopoverContentViewController

    /// 弹层可见性回调（didShow/didClose 触发），供接线方喂给 PopoverVisibilityTracker
    public var onVisibilityChange: ((Bool) -> Void)?

    public init(viewModel: PanelViewModel) {
        contentController = PopoverContentViewController(viewModel: viewModel)
        super.init()
        // transient：点击外部或 Esc 自动收起（A2·S3 交互规格）
        popover.behavior = .transient
        popover.contentViewController = contentController
        popover.delegate = self
    }

    public var isShown: Bool { popover.isShown }

    /// 切换显示（菜单栏按钮点击入口）
    public func toggle(anchorView: NSView) {
        if popover.isShown {
            close()
        } else {
            open(anchorView: anchorView)
        }
    }

    public func open(anchorView: NSView) {
        guard !popover.isShown else { return }
        // preferredEdge .minY：锚点下方弹出（菜单栏图标在屏幕顶部边缘）
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    public func close() {
        popover.performClose(nil)
    }

    // MARK: - NSPopoverDelegate
    // AppKit 保证委托回调在主线程，但 SDK 对该协议的 actor 隔离标注随版本浮动：
    // nonisolated 见证两头兼容，主线程事实由 assumeIsolated 收口回 MainActor

    public nonisolated func popoverDidShow(_ notification: Notification) {
        MainActor.assumeIsolated {
            onVisibilityChange?(true)
        }
    }

    public nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            onVisibilityChange?(false)
        }
    }
}
