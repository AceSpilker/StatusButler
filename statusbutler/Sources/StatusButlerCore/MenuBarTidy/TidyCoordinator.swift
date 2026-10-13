import Combine
import Foundation

// MARK: - 菜单栏整理协调器（T-223 · A9 E3 / MB-01~05 上线半场）
// 串起已有三层：MenubarScanner（发现）→ TidyEngine（纯函数规划）→
// Applier（AX 写入）。本层职责只剩编排与状态面：
//   - 版本门控（MB-04）：门未过 → fail-closed，零扫描零 AX 调用；
//   - AX 状态反馈（needsAccessibilityPermission → 设置页引导文案数据源）；
//   - 启停幂等 + 停用即恢复全部（MB-05"恢复全部并关闭本功能"）；
//   - popover 可见 → 临时展开全部（MB-02 手动模式），收起后按 MB-03
//     闲置宽限重新应用规则（默认 5s，注入 0 供测试）。
// 隐藏状态纯内存（HiddenStateTracker，不落盘）——崩溃即全恢复，永不"永久吞图标"。
//
// ── 集成注记（AppEnvironment/LiveServices 接线——App/ 不归本任务改动面）────
// LiveServices 里四步点亮（与其他 feed 同姿势）：
//   let tidy = TidyCoordinator.live()
//   存为属性（强引用），LiveServices.start() 内 `tidy.start()`；
//   设置开关（SettingsStore 将来加 tidyEnabled/tidyRules 后）：
//     settings.$tidyEnabled.removeDuplicates().sink { tidy.setEnabled($0) }
//     settings.$tidyRules.dropFirst().removeDuplicates().sink { _ in Task { await tidy.runOnce() } }
//   popover 临时展开（StatusPopoverController.onVisibilityChange 回调内）：
//     visible ? await tidy.popoverWillShow() : tidy.popoverDidClose()
//   设置页消费：axStatus（.needsAccessibilityPermission 时显示辅助功能授权
//   引导文案 + 深链系统设置）、managedItems（规则编辑清单）、hiddenCount。
// 规则档案接入前 live() 的 rules 供给为空数组（= 全部默认可见，零隐藏动作）。

/// AX 通道状态（设置页引导文案的数据源）。versionGated 在最前：
/// 版本门没过的机器上连"要不要授权"都不该问（MB-04 fail-closed）。
public enum TidyAXStatus: Equatable, Sendable {
    /// 本机 macOS 未过 VersionGate.axVerifiedMajors 白名单
    case versionGated
    /// 未授辅助功能权限 → 设置面板引导文案
    case needsAccessibilityPermission
    /// 已授权但 AX 树读不出（SystemUIServer 拒读——macOS 26 已知形态，A14-ε）
    case axUnavailable
    case ok
}

@MainActor
public final class TidyCoordinator: ObservableObject {
    // MARK: - 状态面（面板/设置页消费）

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var axStatus: TidyAXStatus = .versionGated
    /// 当前被我们隐藏的条目数（tracker 口径——只数本会话动过的）
    @Published public private(set) var hiddenCount = 0
    /// 最近一轮扫描 + 规划后的受管条目（设置页规则编辑清单）
    @Published public private(set) var managedItems: [MenubarItem] = []

    // MARK: - 注入

    private let scanner: any MenubarScanning
    private let applier: any MenubarTidyApplying
    private let tracker: HiddenStateTracker
    /// 版本门（MB-04）：默认 ProcessInfo 实测；测试注入假门
    private let hostIsSupported: () -> Bool
    /// 图标级枚举器的 fail-visible 状态（.ok 之外才有引导价值）。
    /// 默认 nil（App 级扫描永远可用）——live 装配时接 StatusItemEnumerator.lastStatus
    private let axStatusProbe: () -> StatusItemEnumerator.EnumerationStatus?
    private let rules: () -> [TidyRule]
    private let batteryPercent: () -> Int?
    /// popover 收起后重新隐藏前的闲置宽限（MB-03 默认 5s）
    private let rehideDelay: TimeInterval

    private var started = false
    private var rehideTask: Task<Void, Never>?
    private var isRevealed = false

    public init(
        isEnabled: Bool = false,
        scanner: any MenubarScanning,
        applier: any MenubarTidyApplying,
        tracker: HiddenStateTracker = HiddenStateTracker(),
        hostIsSupported: @escaping () -> Bool = { VersionGate.hostIsSupportedForAX() },
        axStatusProbe: @escaping () -> StatusItemEnumerator.EnumerationStatus? = { nil },
        rules: @escaping () -> [TidyRule] = { [] },
        batteryPercent: @escaping () -> Int? = { nil },
        rehideDelay: TimeInterval = 5
    ) {
        self.isEnabled = isEnabled
        self.scanner = scanner
        self.applier = applier
        self.tracker = tracker
        self.hostIsSupported = hostIsSupported
        self.axStatusProbe = axStatusProbe
        self.rules = rules
        self.batteryPercent = batteryPercent
        self.rehideDelay = rehideDelay
    }

    /// 真装配（版本门内 AX 路线，A14-ε MenubarTidyAssembly 同源件）。
    /// tracker 由本协调器持有并注入 Applier——hiddenCount 的记账口径必须在
    /// 同一本账上，Applier 自己 new 一本会把账算丢。
    public static func live(
        isEnabled: Bool = false,
        rules: @escaping () -> [TidyRule] = { [] },
        batteryPercent: @escaping () -> Int? = { nil }
    ) -> TidyCoordinator {
        let tracker = HiddenStateTracker()
        let enumerator = MenubarTidyAssembly.makeItemEnumerator() as? StatusItemEnumerator
        return TidyCoordinator(
            isEnabled: isEnabled,
            scanner: RunningAppsMenubarScanner(itemEnumerator: MenubarTidyAssembly.makeItemEnumerator()),
            applier: MenubarTidyAssembly.makeApplier(tracker: tracker),
            tracker: tracker,
            hostIsSupported: { VersionGate.hostIsSupportedForAX() },
            axStatusProbe: { [weak enumerator] in enumerator?.lastStatus },
            rules: rules,
            batteryPercent: batteryPercent
        )
    }

    // MARK: - 生命周期（幂等）

    /// 启动：版本门 → 状态面 → 启用则跑一轮。重复调用零副作用（started 门）。
    public func start() async {
        guard !started else { return }
        started = true
        refreshGateAndStatus()
        guard isEnabled else { return }
        await runOnce()
    }

    /// 开关（设置页"启用/恢复全部并关闭"的一键出口）。同值幂等；
    /// 关闭 = 先恢复全部再停（MB-05：关功能绝不能把图标留在隐藏态）。
    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard started else { return }
        if enabled {
            refreshGateAndStatus()
            await runOnce()
        } else {
            await restoreAll()
        }
    }

    /// 一轮：扫描 → 规划 → 应用 → 记账上浮。电池联动规则的重评估入口
    /// （电池变化/规则编辑后由接线层调，见文件头集成注记）。
    public func runOnce() async {
        guard started, isEnabled, hostIsSupported() else {
            if !hostIsSupported() { axStatus = .versionGated }
            return
        }
        // 先扫描再探 AX 状态：枚举器的 lastStatus 是扫描副产物，扫完才是新值
        let current = scanner.scan()
        managedItems = current
        refreshGateAndStatus()

        let target = TidyEngine.plan(current: current, rules: rules(), battery: batteryPercent())
        let changes = TidyEngine.changes(current: current, target: target)
        await applier.apply(changes: changes)
        hiddenCount = await tracker.currentlyHidden().count
    }

    /// 恢复全部（停用/关功能出口）。走"目标全可见"的 diff 让 Applier 的
    /// 记账护栏自己把关：本会话没藏过的一概不写（防误伤系统项）。
    public func restoreAll() async {
        guard started else { return }
        let current = scanner.scan()
        var allVisible = current
        for index in allVisible.indices { allVisible[index].isVisible = true }
        let changes = TidyEngine.changes(current: current, target: allVisible)
        await applier.apply(changes: changes)
        hiddenCount = await tracker.currentlyHidden().count
    }

    // MARK: - popover 临时展开（MB-02 手动模式 / MB-03 闲置宽限）

    /// 弹层展开：临时恢复全部（用户要点被藏的图标）。
    /// 已展开时重复调用幂等（不重复写 AX）。
    public func popoverWillShow() async {
        guard started, isEnabled, hostIsSupported(), !isRevealed else { return }
        isRevealed = true
        rehideTask?.cancel()
        await restoreAll()
    }

    /// 弹层收起：闲置宽限后按规则重新隐藏。宽限期内再次展开会取消重藏
    /// （用户在频繁开关弹层时图标不该闪藏）。
    public func popoverDidClose() {
        guard started, isEnabled, isRevealed else { return }
        let delay = rehideDelay
        rehideTask?.cancel()
        rehideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.isRevealed = false
            await self.runOnce()
        }
    }

    // MARK: - 状态面维护

    /// 版本门 + AX 状态合成。icon 级枚举器缺席（App 级扫描）时视为 ok——
    /// App 级清单永远可用，缺的只是图标粒度。
    private func refreshGateAndStatus() {
        guard hostIsSupported() else {
            axStatus = .versionGated
            return
        }
        switch axStatusProbe() {
        case .needsAccessibilityPermission:
            axStatus = .needsAccessibilityPermission
        case .axUnavailable:
            axStatus = .axUnavailable
        case .ok, nil:
            axStatus = .ok
        }
    }
}
