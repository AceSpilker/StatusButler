import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例锁（A2·S2）：既存实例已激活时本进程立即退场——放在装配之前，
        // 不起监控不建图标，第二实例的代价只有一次进程起落
        guard !SingleInstanceLock.activateExistingInstanceIfPresent() else {
            NSApplication.shared.terminate(nil)
            return
        }
        let environment = AppEnvironment.live()
        self.environment = environment
        environment.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
    }

    // MARK: - Dock 点击（A2·S2）：指针在 Dock 区域→弹层；Launchpad/Spotlight 同事件→开设置；冷启动不动作

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let environment else { return false }
        let pointer = NSEvent.mouseLocation
        switch DockActivationAction.resolve(
            isReopenEvent: Self.currentEventIsReopen(),
            hasDockTile: environment.hasDockTile,
            isPointerInDockArea: Self.isPointerInDockArea(pointer)
        ) {
        case .showPopover:
            environment.togglePopoverFromStatusBar()
        case .openSettings:
            environment.showSettingsWindow()
        case .none:
            break
        }
        return false
    }

    /// Dock 图标点击送达的是 reopen 事件；冷启动（含登录项拉起）不走这里，
    /// 但部分启动路径仍可能到 shouldHandleReopen——以当前 Apple Event 为准，不许误弹
    private static func currentEventIsReopen() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventClass == AEEventClass(kCoreEventClass)
            && event.eventID == AEEventID(kAEReopenApplication)
    }

    private static func isPointerInDockArea(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return false
        }
        let placement = DockPlacement.resolve(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        return placement.containsPointer(
            point,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}
