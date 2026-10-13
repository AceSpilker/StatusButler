import Foundation
import Testing

@testable import StatusButlerCore

// T-223 TidyCoordinator：版本门 fail-closed / AX 状态反馈 / 扫描→规划→应用编排 /
// 停用恢复全部 / popover 临时展开与宽限重藏 / 启停幂等。全假件（假扫描器 +
// 记账 Applier），零 AX 零 WindowServer——CI 可跑；真 AX 行为已由
// MenubarTidyAXTests 覆盖，本套件只测协调器自己的编排语义。

// MARK: - 假件

@MainActor
private final class FakeMenubarScanner: MenubarScanning {
    /// 可见态盒：Applier 写（隐藏/恢复）→ scan 读——模拟 AX 宽度 0/原宽的
    /// 真实反馈环，否则连续轮次的 diff 永远看不到"已隐藏"的现态
    final class VisibilityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hidden: Set<String> = []
        func setHidden(_ identifier: String, _ hidden: Bool) {
            lock.withLock {
                if hidden { _ = self.hidden.insert(identifier) } else { _ = self.hidden.remove(identifier) }
            }
        }
        func isHidden(_ identifier: String) -> Bool {
            lock.withLock { hidden.contains(identifier) }
        }
    }

    let visibility = VisibilityBox()
    var items: [MenubarItem] = []
    private(set) var scanCount = 0

    func scan() -> [MenubarItem] {
        scanCount += 1
        return items.map { item in
            var copy = item
            copy.isVisible = !visibility.isHidden(item.identifier)
            return copy
        }
    }
}

/// 记账 Applier：复刻 AXMenubarApplier 的账本纪律（隐藏先记账、恢复只碰记过账的），
/// 让 hiddenCount 经真 HiddenStateTracker 口径流转
private actor FakeRecordingApplier: MenubarTidyApplying {
    private(set) var applied: [[(item: MenubarItem, to: Bool)]] = []
    private let tracker: HiddenStateTracker
    private let visibility: FakeMenubarScanner.VisibilityBox

    init(tracker: HiddenStateTracker, visibility: FakeMenubarScanner.VisibilityBox) {
        self.tracker = tracker
        self.visibility = visibility
    }

    func apply(changes: [(item: MenubarItem, to: Bool)]) async {
        applied.append(changes)
        for (item, to) in changes {
            if to {
                if await tracker.currentlyHidden().contains(item.identifier) {
                    await tracker.recordRestored(item.identifier)
                    visibility.setHidden(item.identifier, false)
                }
            } else {
                await tracker.recordHidden(item.identifier)
                visibility.setHidden(item.identifier, true)
            }
        }
    }

    var totalChangeCount: Int { applied.reduce(0) { $0 + $1.count } }
}

private func makeItems() -> [MenubarItem] {
    [
        MenubarItem(ownerAppName: "Zoom", identifier: "us.zoom.xos"),
        MenubarItem(ownerAppName: "Music", identifier: "com.apple.Music"),
        MenubarItem(ownerAppName: "Dropbox", identifier: "com.dropbox.dropbox"),
    ]
}

@MainActor
@Suite struct T223TidyCoordinatorTests {

    private func makeCoordinator(
        scanner: FakeMenubarScanner,
        applier: FakeRecordingApplier,
        tracker: HiddenStateTracker,
        gate: @escaping () -> Bool = { true },
        probe: StatusItemEnumerator.EnumerationStatus?? = nil,
        rules: [TidyRule] = [],
        battery: Int? = nil,
        rehideDelay: TimeInterval = 5
    ) -> TidyCoordinator {
        var probeValue: StatusItemEnumerator.EnumerationStatus?
        if let probe { probeValue = probe }
        return TidyCoordinator(
            scanner: scanner,
            applier: applier,
            tracker: tracker,
            hostIsSupported: gate,
            axStatusProbe: { probeValue },
            rules: { rules },
            batteryPercent: { battery },
            rehideDelay: rehideDelay
        )
    }

    // MARK: - 版本门（MB-04 fail-closed）

    @Test func versionGateFailsClosedWithZeroScanAndZeroApply() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(scanner: scanner, applier: applier, tracker: tracker, gate: { false })

        await coordinator.start()
        await coordinator.setEnabled(true)
        await coordinator.runOnce()  // 显式再戳一轮：门关必须持续拦
        #expect(coordinator.axStatus == .versionGated)
        #expect(scanner.scanCount == 0, "未过白名单的 macOS 上零扫描零 AX 调用")
        #expect(await applier.totalChangeCount == 0)
        #expect(coordinator.managedItems.isEmpty)
    }

    // MARK: - AX 状态反馈（设置页引导文案数据源）

    @Test func permissionMissingFlagsGuidanceAfterScan() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(
            scanner: scanner, applier: applier, tracker: tracker,
            probe: .some(.needsAccessibilityPermission)
        )
        await coordinator.start()
        await coordinator.setEnabled(true)
        #expect(coordinator.axStatus == .needsAccessibilityPermission)
        // App 级扫描不依赖授权：清单照常上浮（引导文案与功能数据互不阻塞）
        #expect(coordinator.managedItems.count == 3)
    }

    @Test func axUnavailableSurfacesAsHonestStatus() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(
            scanner: scanner, applier: applier, tracker: tracker, probe: .some(.axUnavailable)
        )
        await coordinator.start()
        await coordinator.setEnabled(true)
        #expect(coordinator.axStatus == .axUnavailable)
    }

    // MARK: - 启用轮：扫描 → 规划 → 应用 → 记账

    @Test func enabledCyclePlansAndAppliesRuleChanges() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(
            scanner: scanner, applier: applier, tracker: tracker,
            rules: [.alwaysHide(identifier: "us.zoom.xos")]
        )
        await coordinator.start()
        await coordinator.setEnabled(true)

        let batches = await applier.applied
        #expect(batches.count == 1)
        #expect(batches[0].count == 1, "只有 Zoom 命中 alwaysHide，其余默认可见不动")
        #expect(batches[0][0].item.identifier == "us.zoom.xos")
        #expect(batches[0][0].to == false)
        #expect(coordinator.hiddenCount == 1)
        #expect(coordinator.managedItems.count == 3)
    }

    // MARK: - 停用 = 恢复全部（MB-05 一键出口）

    @Test func disableRestoresAllThenIdempotent() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(
            scanner: scanner, applier: applier, tracker: tracker,
            rules: [.alwaysHide(identifier: "us.zoom.xos")]
        )
        await coordinator.start()
        await coordinator.setEnabled(true)
        #expect(coordinator.hiddenCount == 1)

        await coordinator.setEnabled(false)
        var batches = await applier.applied
        #expect(batches.count == 2)
        #expect(batches[1].count == 1)
        #expect(batches[1][0].to == true, "关闭必须先把藏了的恢复回可见")
        #expect(coordinator.hiddenCount == 0)
        #expect(!coordinator.isEnabled)

        let changesBefore = await applier.totalChangeCount
        await coordinator.setEnabled(false)  // 同值幂等：不重复恢复、不重复扫描
        batches = await applier.applied
        #expect(batches.count == 2)
        #expect(await applier.totalChangeCount == changesBefore)
    }

    // MARK: - 启停幂等

    @Test func startIsIdempotent() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = TidyCoordinator(
            isEnabled: true,
            scanner: scanner,
            applier: applier,
            hostIsSupported: { true },
            rules: { [] },
            rehideDelay: 0
        )

        await coordinator.start()
        await coordinator.start()  // 重复 start 零副作用
        await coordinator.start()

        #expect(scanner.scanCount == 1, "三次 start 只跑一轮扫描")
        let batches = await applier.applied
        #expect(batches.allSatisfy { $0.isEmpty }, "无规则时 changes 恒空：起服务本身不藏任何东西")
        #expect(coordinator.hiddenCount == 0)
    }

    // MARK: - popover 临时展开 + 宽限重藏（MB-02/03）

    @Test func popoverRevealThenRehideAfterGraceDelay() async throws {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        let coordinator = makeCoordinator(
            scanner: scanner, applier: applier, tracker: tracker,
            rules: [.alwaysHide(identifier: "us.zoom.xos")],
            rehideDelay: 0  // 测试注入零宽限；生产默认 5s（MB-03 闲置宽限）
        )
        await coordinator.start()
        await coordinator.setEnabled(true)
        #expect(coordinator.hiddenCount == 1)

        await coordinator.popoverWillShow()  // 弹层展开：临时恢复全部
        var batches = await applier.applied
        #expect(batches.count == 2)
        #expect(batches[1][0].to == true)
        #expect(coordinator.hiddenCount == 0)

        coordinator.popoverDidClose()  // 收起：宽限后按规则重新隐藏
        let rehidden = await pollUntil(timeout: 3) { [coordinator] in coordinator.hiddenCount == 1 }
        #expect(rehidden, "宽限后应重新隐藏 Zoom")
        batches = await applier.applied
        #expect(batches.count == 3)
        #expect(batches[2][0].to == false)

        // 弹层展开幂等：已展开时重复调用不重复写
        let before = await applier.totalChangeCount
        await coordinator.popoverWillShow()
        await coordinator.popoverWillShow()
        #expect(await applier.totalChangeCount == before + 1, "只恢复一次")
    }

    // MARK: - 电池联动重评估入口

    @Test func batteryLinkedRuleReevaluatesOnRunOnce() async {
        let scanner = FakeMenubarScanner()
        scanner.items = makeItems()
        let tracker = HiddenStateTracker()
        let applier = FakeRecordingApplier(tracker: tracker, visibility: scanner.visibility)
        // Music 仅在电量低于 50% 时显示：电量 80（≥ 阈值）→ 藏
        let drained = TidyCoordinator(
            scanner: scanner,
            applier: applier,
            rules: { [.showOnlyWhen(appIdentifier: "com.apple.Music", batteryBelow: 50)] },
            batteryPercent: { 80 },
            rehideDelay: 0
        )
        await drained.start()
        await drained.setEnabled(true)
        var batches = await applier.applied
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
        #expect(batches[0][0].item.identifier == "com.apple.Music")
        #expect(batches[0][0].to == false, "电量 80 未低于 50 → Music 收纳")

        // 电量降到 30（< 阈值）→ Music 该显示：runOnce 是接线层的重评估入口
        let lowBattery = TidyCoordinator(
            scanner: scanner,
            applier: applier,
            rules: { [.showOnlyWhen(appIdentifier: "com.apple.Music", batteryBelow: 50)] },
            batteryPercent: { 30 },
            rehideDelay: 0
        )
        await lowBattery.start()
        await lowBattery.setEnabled(true)
        batches = await applier.applied
        #expect(batches.count == 2)
        #expect(batches[1][0].to == true, "电量 30 低于 50 → Music 恢复显示")
        #expect(lowBattery.hiddenCount == 0)
    }
}

@MainActor
private func pollUntil(
    timeout: TimeInterval,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
