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

    // MARK: - 屏幕坐标锚定（T-210 Dock 真点位弹层锚定）
    //
    // NSPopover 只能相对视图锚定，而 Dock 点击场景（applicationShouldHandleReopen →
    // DockActivationAction.resolve == .showPopover）手里只有屏幕坐标——本入口在
    // 目标点位临时架一块 1×1 透明非激活面板，弹层相对其锚视图弹出，关闭即一并撤除。
    //
    // 集成注记（App 侧调用点改法，AppEnvironment.togglePopoverFromStatusBar）：
    //   旧（只有菜单栏锚，Dock 点击被迫借菜单栏位置或降级开设置）：
    //     if let button = statusBarController.anchorButton {
    //         popoverController.toggle(anchorView: button)
    //     } else {
    //         settingsWindowController.showWindow(nil)
    //     }
    //   新（Dock 路径传 reopen 事件发生时的真实指针点位）：
    //     popoverController.toggle(at: NSEvent.mouseLocation)
    //   菜单栏点击仍走 toggle(anchorView:)——两入口并存，互不替代。

    /// 屏幕坐标锚定窗（Dock 点击等无锚点视图场景的生命周期持有；弹层关闭即撤）
    private var anchorWindow: NSWindow?

    /// 测试与接线方可观测：屏幕锚定窗是否在役（关闭后必须归 false，防孤儿窗泄漏）
    public var hasScreenAnchorWindow: Bool { anchorWindow != nil }

    /// 屏幕坐标切换显示（Dock 图标点击入口）
    public func toggle(at screenPoint: NSPoint) {
        if popover.isShown {
            close()
        } else {
            show(at: screenPoint)
        }
    }

    /// 屏幕坐标弹出：preferredEdge .maxY（Dock 在屏幕底缘，弹层从点位上方展开）
    public func show(at screenPoint: NSPoint) {
        guard !popover.isShown else { return }
        guard let window = makeAnchorWindow(at: screenPoint),
              let anchor = window.contentView?.subviews.first
        else { return }
        anchorWindow = window
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // show 失败（极端：无 WindowServer 的 headless 环境）不留孤儿锚定窗
        if !popover.isShown {
            teardownAnchorWindow()
        }
    }

    /// 点位 → 锚定窗 frame（纯函数，无 WindowServer 也可单测屏幕选择与钳制）：
    /// 点在某屏内原样用；都不含（陈旧坐标等）钳进 fallback 屏；无屏可用返回 .zero
    /// （调用方放弃弹出——比弹在看不见的地方诚实）
    nonisolated static func anchorFrame(
        at point: NSPoint,
        screenFrames: [NSRect],
        fallback: NSRect?
    ) -> NSRect {
        guard let base = screenFrames.first(where: { NSPointInRect(point, $0) }) ?? fallback else {
            return .zero
        }
        let x = min(max(point.x, base.minX), base.maxX - 1)
        let y = min(max(point.y, base.minY), base.maxY - 1)
        return NSRect(x: x, y: y, width: 1, height: 1)
    }

    /// 1×1 透明非激活面板 + 零尺寸语义锚视图。前后台安全：nonactivatingPanel +
    /// orderFrontRegardless——后台 App 收到 Dock 点击时弹层照常出现且不抢当前焦点；
    /// ignoresMouseEvents 让锚窗只借位置、不挡 Dock 与桌面点击
    private func makeAnchorWindow(at screenPoint: NSPoint) -> NSWindow? {
        let screens = NSScreen.screens.map(\.frame)
        let frame = Self.anchorFrame(
            at: screenPoint, screenFrames: screens, fallback: NSScreen.main?.frame
        )
        guard frame != .zero else { return nil }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
        panel.orderFrontRegardless()
        return panel
    }

    private func teardownAnchorWindow() {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
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
            // 屏幕锚定窗与弹层同生命周期：弹层收起（transient 点外/Esc/程序关闭）即撤，
            // 不留一块 1×1 隐形窗在桌面
            teardownAnchorWindow()
            onVisibilityChange?(false)
        }
    }
}
