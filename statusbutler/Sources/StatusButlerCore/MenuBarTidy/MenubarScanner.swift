import AppKit

// MARK: - 发现层（T-053a · A9 MB-01，诚实降级版）
// 目标形态是枚举其他 App 的 NSStatusItem（MB-01）。图标级枚举两条技术路线的调研结论：
// 1) NSStatusBar 私有 ivar（_items 等）：只含本进程注册的 item——其他 App 的 item
//    宿主在各自进程、布局权在 SystemUIServer，本进程读私有 ivar 永远只见自家图标；
//    跨进程方案要注入 SystemUIServer，既不可行也过不了沙盒/公证的现实约束。此路对本需求不通。
// 2) CGWindow 层：CGWindowListCopyWindowInfo 可按窗口 layer/owner 识别"哪些 App 在
//    菜单栏有存在感"（窗口名在无屏幕录制权限时被系统脱敏），粒度止步于 App 级；
//    定位并操控单个 item 仍需再叠 AX 私有属性，版本脆弱性最高——MB-04 版本白名单的由来。
// 结论：本版交付公开 API 的 App 级候选清单（NSRunningApplication，.regular + .accessory；
// accessory 即 LSUIElement，无 Dock 图标但正是挂状态栏的主力）+ 完整规则引擎；
// 图标级枚举做成 MenubarItemEnumerating 注入点（stub 返回空），待实机回归并过 MB-04
// 白名单后在 T-053b 接入真实现。
// CI/headless 安全：NSWorkspace 在无 GUI 会话返回空列表，scan() 不崩、不抛、不需要权限。

@MainActor
public protocol MenubarScanning: Sendable {
    func scan() -> [MenubarItem]
}

/// 图标级（NSStatusItem 粒度）枚举注入点：真实现依赖私有视图树（路线 1/2 的组合），
/// 本包只留契约与 stub，保证规则引擎可以先于枚举层交付并被测试。
@MainActor
public protocol MenubarItemEnumerating: Sendable {
    func enumerateItems() -> [MenubarItem]
}

/// 占位实现：诚实返回空，调用方自动退回 App 级候选清单。
public struct StubMenubarItemEnumerator: MenubarItemEnumerating {
    public init() {}

    public func enumerateItems() -> [MenubarItem] { [] }
}

/// App 级候选清单扫描器（公开 AppKit）。图标级枚举可注入，同 identifier 时图标级条目胜出。
@MainActor
public struct RunningAppsMenubarScanner: MenubarScanning {
    private let itemEnumerator: any MenubarItemEnumerating

    public init(itemEnumerator: any MenubarItemEnumerating = StubMenubarItemEnumerator()) {
        self.itemEnumerator = itemEnumerator
    }

    public func scan() -> [MenubarItem] {
        let iconLevel = itemEnumerator.enumerateItems()
        let appLevel = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .map { app in
                // 个别系统进程拿不到 bundle id：回退 pid 标识，保证 identifier 非空、规则可匹配
                let fallback = "pid.\(app.processIdentifier)"
                return MenubarItem(
                    ownerAppName: app.localizedName ?? app.bundleIdentifier ?? fallback,
                    title: nil,
                    identifier: app.bundleIdentifier ?? fallback,
                    isVisible: true  // App 级探测读不到图标真实可见性：保守占位 true，真值由图标级枚举补齐
                )
            }
        return Self.mergedItems(iconLevel: iconLevel, appLevel: appLevel)
    }

    /// 合并去重 + 稳定排序（纯函数便于测试）：先见者胜——图标级在前，
    /// 其信息量（title/真实可见性）大于 App 级候选，同 identifier 时顶掉后者。
    /// nonisolated：纯映射，不触碰 AppKit，不该背上主线程隔离。
    nonisolated static func mergedItems(iconLevel: [MenubarItem], appLevel: [MenubarItem]) -> [MenubarItem] {
        var seen = Set<String>()
        var merged: [MenubarItem] = []
        for item in iconLevel + appLevel where seen.insert(item.identifier).inserted {
            merged.append(item)
        }
        return merged.sorted { ($0.ownerAppName, $0.identifier) < ($1.ownerAppName, $1.identifier) }
    }
}
