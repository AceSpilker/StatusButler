import AppKit
import ApplicationServices
import Foundation

// MARK: - AX 写入桥 + Applier（MB-01 隐藏/恢复执行层，A14-ε 实装 T-053b 契约）
// 遵守 TidyEngine 文末集成铁律：隐藏先记账后写；恢复只碰本会话记过账的条目；
// 写失败静默记账不重试风暴。新增自保：连续写失败达阈值自动禁用——写通道环境性
// 坏掉（授权被撤/SystemUIServer 重启循环）时继续空转只会制造半隐藏态，宁可停手。

/// AX 写入门面（测试注入假写工厂）。目标定位链必须与 StatusItemEnumerator 的
/// identifier 回退链一致（AXIdentifier 优先、缺席比 AXDescription）——
/// 否则"枚举出来的名字"写不回目标。
@MainActor
public protocol MenubarAXWriting: Sendable {
    /// 目标当前宽度；找不到目标/读失败 → nil
    func currentWidth(forIdentifier identifier: String) -> CGFloat?
    /// 设目标宽度（高度保持 AX 树原值——只动 width 是 MB-01 的最小干预面）。
    /// 找不到目标/AX 拒写 → false（不抛：写失败是环境态不是程序错误）
    @discardableResult
    func setWidth(_ width: CGFloat, forIdentifier identifier: String) -> Bool
}

/// 真实现。每次调用即时解析目标元素：AXUIElement 引用跨 SystemUIServer 重启即失效，
/// 不缓存是刻意的——写路径宁可每次多一次树查询，不持过期引用写错对象。
@MainActor
public struct SystemUIServerAXWriter: MenubarAXWriting {
    public init() {}

    public func currentWidth(forIdentifier identifier: String) -> CGFloat? {
        element(forIdentifier: identifier).flatMap { MenubarAXSupport.size($0)?.width }
    }

    public func setWidth(_ width: CGFloat, forIdentifier identifier: String) -> Bool {
        guard let element = element(forIdentifier: identifier),
              var size = MenubarAXSupport.size(element)
        else { return false }
        size.width = width
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    /// 定位：全部菜单栏子项里第一个 identifier 命中的元素（回退链同枚举器：
    /// 先比 AXIdentifier，缺席比 AXDescription）
    private func element(forIdentifier identifier: String) -> AXUIElement? {
        guard let pid = MenubarAXSupport.systemUIServerPID() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        for bar in MenubarAXSupport.menuBarElements(of: appElement) {
            for item in MenubarAXSupport.children(of: bar) {
                let candidate = MenubarAXSupport.string(item, kAXIdentifierAttribute)
                    ?? MenubarAXSupport.string(item, kAXDescriptionAttribute)
                if candidate == identifier { return item }
            }
        }
        return nil
    }
}

// MARK: - Applier
@MainActor
public final class AXMenubarApplier: MenubarTidyApplying {
    /// 连续写失败上限。取"连续"而非"累计"：SystemUIServer 重启类故障表现为一段失败后
    /// 自愈，成功一次即清零；累计会把远期偶发噪声攒成误禁。
    public static let consecutiveFailureLimit = 5

    /// 恢复兜底宽度：正常路径写回"记账过的原宽"，此值只在账本意外缺失时兜底
    /// （NSStatusItem 默认长度档 ≈ 28pt，比"留在 0 即永久吞图标"诚实——MB-05）
    public static let fallbackRestoreWidth: CGFloat = 28

    public private(set) var isDisabled = false
    public private(set) var consecutiveFailures = 0

    /// 自动禁用回调（集成挂提示/toast；轮询 isDisabled 亦可）。fire 一次后引擎停在禁用态
    public var onDisabled: (@MainActor () -> Void)?

    private let writer: any MenubarAXWriting
    private let tracker: HiddenStateTracker
    /// 本会话隐藏时记下的原宽。与 tracker 同生命周期纯内存（MB-05：崩溃即丢，
    /// 下次登录一切以系统默认可见态重来——绝不持久化隐藏状态）
    private var originalWidths: [String: CGFloat] = [:]

    public init(
        writer: any MenubarAXWriting = SystemUIServerAXWriter(),
        tracker: HiddenStateTracker = HiddenStateTracker()
    ) {
        self.writer = writer
        self.tracker = tracker
    }

    public func apply(changes: [(item: MenubarItem, to: Bool)]) async {
        guard !isDisabled else { return }  // 禁用即零写（恢复走 restoreAllNow 专属出口）
        for (item, to) in changes {
            if to {
                await restore(item)
            } else {
                await hide(item)
            }
        }
    }

    /// 隐藏：先读原宽再写 0（写完 0 原宽就丢了）；写失败不记 hidden——账本不留半套状态
    private func hide(_ item: MenubarItem) async {
        if originalWidths[item.identifier] == nil {
            originalWidths[item.identifier] =
                writer.currentWidth(forIdentifier: item.identifier) ?? Self.fallbackRestoreWidth
        }
        guard writer.setWidth(0, forIdentifier: item.identifier) else {
            noteFailure()
            return
        }
        consecutiveFailures = 0
        await tracker.recordHidden(item.identifier)
    }

    /// 恢复：只碰 tracker 记过账的（防误伤系统项——本会话不是我们藏的一概不写）
    private func restore(_ item: MenubarItem) async {
        guard await tracker.currentlyHidden().contains(item.identifier) else { return }
        let width = originalWidths[item.identifier] ?? Self.fallbackRestoreWidth
        guard writer.setWidth(width, forIdentifier: item.identifier) else {
            noteFailure()
            return
        }
        consecutiveFailures = 0
        originalWidths[item.identifier] = nil
        await tracker.recordRestored(item.identifier)
    }

    private func noteFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.consecutiveFailureLimit, !isDisabled else { return }
        isDisabled = true
        onDisabled?()
    }

    /// "恢复全部并关闭本功能"的一键出口（MB-05 / TidyEngine 铁律 3）。
    /// 不走 isDisabled 门——被禁用恰恰是"必须恢复"的信号源之一。
    /// 尽力恢复（单项失败不中断其余），但不清 isDisabled：通道修好与否与恢复是两件事，
    /// 重新启用引擎是设置页的显式动作。
    public func restoreAllNow() async {
        let identifiers = await tracker.restoreAll()
        for identifier in identifiers {
            let width = originalWidths[identifier] ?? Self.fallbackRestoreWidth
            _ = writer.setWidth(width, forIdentifier: identifier)
            originalWidths[identifier] = nil
        }
        consecutiveFailures = 0
    }
}

// MARK: - 装配门（版本门控真实接入 · MB-04）
/// 组合根唯一装配点：门开（ProcessInfo 实测大版本 ∈ VersionGate.axVerifiedMajors）→ AX 真件；
/// 门关 → stub/Null（fail-closed：未验证版本上零 AX 调用）。真件装配后枚举器侧的环境
/// 失败（无授权/树读不出）再由 lastStatus/isDisabled 二级降级——两级门各管一层：
/// 版本门管"这个 macOS 我们敢不敢用"，状态门管"这台机器现在能不能用"。
public enum MenubarTidyAssembly {
    @MainActor
    public static func makeItemEnumerator() -> any MenubarItemEnumerating {
        VersionGate.hostIsSupportedForAX() ? StatusItemEnumerator() : StubMenubarItemEnumerator()
    }

    @MainActor
    public static func makeApplier(tracker: HiddenStateTracker = HiddenStateTracker()) -> any MenubarTidyApplying {
        VersionGate.hostIsSupportedForAX() ? AXMenubarApplier(tracker: tracker) : NullMenubarTidyApplier()
    }
}
