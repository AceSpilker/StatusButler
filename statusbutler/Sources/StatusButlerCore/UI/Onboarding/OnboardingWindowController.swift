import AppKit
import SwiftUI

// T-032: 首次引导窗口壳（A2·S10 OG-FR-190：只自动弹一次，设置里可重开）
// 持久化归集成方：完成回调里写 UserDefaults[OnboardingWindowController.defaultsKey]，
// 下次启动读出后传入 showIfNeeded(hasSeenGuide:)——本类不直接碰 UserDefaults（入参注入，测试无副作用）

@MainActor
public final class OnboardingWindowController {
    /// 建议的持久化键：与 SettingsStore 既有键风格一致，由集成方消费
    public static let defaultsKey = "hasSeenOnboardingGuide"

    private let localization: Localization
    private let onFinish: (() -> Void)?
    /// 只读暴露：测试与集成方据此断言窗口是否在（不弹时保持 nil）
    public private(set) var window: NSWindow?

    public init(
        localization: Localization = Localization(language: .system),
        onFinish: (() -> Void)? = nil
    ) {
        self.localization = localization
        self.onFinish = onFinish
    }

    /// 首次启动入口：看过引导就不弹；返回是否实际弹出（测试与日志消费）
    @discardableResult
    public func showIfNeeded(hasSeenGuide: Bool) -> Bool {
        guard !hasSeenGuide else { return false }
        show()
        return true
    }

    /// 设置"重看引导"入口：已开着就前置同一窗口，否则新开
    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // swift test 等宿主可能尚无 NSApp 单例：先补齐，makeKeyAndOrderFront 才有落点
        if NSApp == nil { _ = NSApplication.shared }

        let content = OnboardingView(localization: localization) { [weak self] in
            self?.complete()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localization.string(.onboardingTitle)
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isReleasedWhenClosed = false  // 关闭只藏不销毁：生命周期归本控制器
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 完成引导（点"开始使用"）：关窗并通知集成方落 UserDefaults
    public func complete() {
        window?.orderOut(nil)
        window = nil
        onFinish?()
    }
}
