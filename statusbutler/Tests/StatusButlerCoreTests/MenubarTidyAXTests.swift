import Foundation
import Testing
@testable import StatusButlerCore

// A14-ε（E3 · MB-01/04/05 实装）：枚举器状态机 / Applier 记账矩阵 / 写失败自禁 /
// 版本门真实名单。全走假 AX 工厂——真 AX 依赖授权与本机 SystemUIServer 状态，
// 环境行为差异恰好是版本门与 fail-visible 要治理的对象（不进确定性断言）。

// MARK: - 假件

@MainActor
final class FakeAXAccess: MenubarAXAccessing {
    var trusted = false
    var snapshot: MenubarAXSnapshot?

    func isProcessTrusted() -> Bool { trusted }
    func snapshotSystemMenuBar() -> MenubarAXSnapshot? { snapshot }
}

@MainActor
final class FakeAXWriter: MenubarAXWriting {
    /// 当前宽度表：键存在 = 元素定位成功；值 = AXSize.width
    var widths: [String: CGFloat] = [:]
    private(set) var setCalls: [(identifier: String, width: CGFloat)] = []
    var failAllSets = false

    func resetCalls() { setCalls.removeAll() }

    func currentWidth(forIdentifier identifier: String) -> CGFloat? {
        widths[identifier]
    }

    func setWidth(_ width: CGFloat, forIdentifier identifier: String) -> Bool {
        guard !failAllSets, widths[identifier] != nil else { return false }
        widths[identifier] = width
        setCalls.append((identifier, width))
        return true
    }
}

// MARK: - 枚举器

@MainActor
@Suite struct MenubarTidyAXTests {

    // MARK: - StatusItemEnumerator（fail-visible 状态机）

    @Test func enumeratorWithoutPermissionReturnsEmptyAndFlagsStatus() {
        let enumerator = StatusItemEnumerator(ax: FakeAXAccess())  // trusted = false
        #expect(enumerator.enumerateItems().isEmpty)
        #expect(enumerator.lastStatus == .needsAccessibilityPermission)
    }

    @Test func enumeratorFlagsAxUnavailableWhenTreeUnreadable() {
        let access = FakeAXAccess()
        access.trusted = true
        access.snapshot = nil  // SystemUIServer 拒读（本机 macOS 26 实测形态）
        let enumerator = StatusItemEnumerator(ax: access)
        #expect(enumerator.enumerateItems().isEmpty)
        #expect(enumerator.lastStatus == .axUnavailable)
    }

    @Test func enumeratorMapsRowsWithIdentifierFallbackChain() {
        let access = FakeAXAccess()
        access.trusted = true
        access.snapshot = MenubarAXSnapshot(rows: [
            MenubarAXRow(identifier: "us.zoom.xos", descriptionText: "Zoom", width: 36),
            MenubarAXRow(identifier: nil, descriptionText: "蓝牙", width: 24),  // 回退到描述
            MenubarAXRow(identifier: nil, descriptionText: nil, width: 0),  // 全缺席：序号占位 + 隐藏态
        ])
        let items = StatusItemEnumerator(ax: access).enumerateItems()
        #expect(items.count == 3)
        #expect(items[0].identifier == "us.zoom.xos")
        #expect(items[1].identifier == "蓝牙")
        #expect(items[1].ownerAppName == "蓝牙")  // 描述文本作 App 名近似（公开 API 上限）
        #expect(items[2].identifier == "ax.2")
        #expect(items.map(\.isVisible) == [true, true, false])  // 宽度 0 = 已隐藏
        #expect(Self.lastStatusOf(ax: access) == .ok)  // ok 态回归
    }

    /// 测试助手：跑一次枚举读终态（避免用例里两条语句间状态被误读）
    @MainActor
    static func lastStatusOf(ax: any MenubarAXAccessing) -> StatusItemEnumerator.EnumerationStatus {
        let enumerator = StatusItemEnumerator(ax: ax)
        _ = enumerator.enumerateItems()
        return enumerator.lastStatus
    }

    @Test func realAXAccessorIsHeadlessSafe() {
        // live 冒烟：真件在任何环境（无授权/无 GUI/SystemUIServer 拒读）都不崩；
        // 返回值契约（Bool/可选快照）保持成立——环境差异交给 lastStatus 表达
        let access = SystemUIServerAXAccessing()
        _ = access.isProcessTrusted()
        if let snapshot = access.snapshotSystemMenuBar() {
            #expect(snapshot.rows.allSatisfy { $0.width >= 0 })
        }
    }

    // MARK: - AXMenubarApplier（记账矩阵）

    private func makeApplier(writer: FakeAXWriter) -> (AXMenubarApplier, HiddenStateTracker) {
        let tracker = HiddenStateTracker()
        return (AXMenubarApplier(writer: writer, tracker: tracker), tracker)
    }

    private func change(_ identifier: String, to: Bool) -> (item: MenubarItem, to: Bool) {
        (MenubarItem(ownerAppName: "X", identifier: identifier), to)
    }

    @Test func hideWritesZeroAndRecordsLedgerAndTracker() async {
        let writer = FakeAXWriter()
        writer.widths["us.zoom.xos"] = 36
        let (applier, tracker) = makeApplier(writer: writer)

        await applier.apply(changes: [change("us.zoom.xos", to: false)])
        #expect(writer.setCalls.count == 1)
        #expect(writer.setCalls[0].identifier == "us.zoom.xos")
        #expect(writer.setCalls[0].width == 0)  // 写 0（隐藏）
        #expect(writer.widths["us.zoom.xos"] == 0)
        #expect(await tracker.currentlyHidden() == ["us.zoom.xos"])  // 先写成功后记账
    }

    @Test func restoreOnlyTouchesTrackedItems() async {
        // 交互矩阵：[藏过的→恢复原宽] × [没藏过的→零写]
        let writer = FakeAXWriter()
        writer.widths["us.zoom.xos"] = 36
        writer.widths["com.apple.controlcenter"] = 40  // 系统项：从未由我们隐藏
        let (applier, tracker) = makeApplier(writer: writer)
        await applier.apply(changes: [change("us.zoom.xos", to: false)])
        writer.resetCalls()

        await applier.apply(changes: [
            change("us.zoom.xos", to: true),
            change("com.apple.controlcenter", to: true),
        ])
        #expect(writer.setCalls.count == 1)
        #expect(writer.setCalls[0].identifier == "us.zoom.xos")
        #expect(writer.setCalls[0].width == 36)  // 只恢复记账项，且是记账原宽
        #expect(writer.widths["com.apple.controlcenter"] == 40)  // 系统项原值未动
        #expect(await tracker.currentlyHidden().isEmpty)
    }

    @Test func unhideWithoutLedgerFallsBackToDefaultWidth() async {
        // 账本意外缺失（防御分支）：兜底宽度恢复，绝不停留在 0（MB-05 不永久吞图标）
        let writer = FakeAXWriter()
        writer.widths["ghost.item"] = 0  // tracker 有账但宽度表从 0 出发（模拟账本丢失）
        let (applier, tracker) = makeApplier(writer: writer)
        await tracker.recordHidden("ghost.item")

        await applier.apply(changes: [change("ghost.item", to: true)])
        #expect(writer.setCalls.count == 1)
        #expect(writer.setCalls[0].identifier == "ghost.item")
        #expect(writer.setCalls[0].width == AXMenubarApplier.fallbackRestoreWidth)
        #expect(await tracker.currentlyHidden().isEmpty)
    }

    @Test func consecutiveWriteFailuresAutoDisableThenApplyIsNoop() async {
        let writer = FakeAXWriter()
        writer.failAllSets = true  // 通道环境性坏掉（授权被撤/SystemUIServer 重启循环）
        let (applier, _) = makeApplier(writer: writer)

        var disabledCallbackFired = false
        applier.onDisabled = { disabledCallbackFired = true }

        // 连续失败 N-1 次：未禁用
        for _ in 1..<(AXMenubarApplier.consecutiveFailureLimit) {
            await applier.apply(changes: [change("a.item", to: false)])
        }
        #expect(!applier.isDisabled)

        // 第 N 次失败：自动禁用 + 回调
        await applier.apply(changes: [change("a.item", to: false)])
        #expect(applier.isDisabled)
        #expect(disabledCallbackFired)

        // 禁用后 apply 零写
        writer.resetCalls()
        writer.failAllSets = false
        writer.widths["b.item"] = 30
        await applier.apply(changes: [change("b.item", to: false)])
        #expect(writer.setCalls.isEmpty)
    }

    @Test func successfulWriteResetsConsecutiveFailureCounter() async {
        let writer = FakeAXWriter()
        writer.widths["flaky.item"] = 30
        let (applier, _) = makeApplier(writer: writer)

        writer.failAllSets = true
        for _ in 1..<(AXMenubarApplier.consecutiveFailureLimit) { await applier.apply(changes: [change("flaky.item", to: false)]) }
        writer.failAllSets = false  // 通道自愈（SystemUIServer 重启完成）
        await applier.apply(changes: [change("flaky.item", to: false)])  // 成功 → 清零
        #expect(!applier.isDisabled)
        #expect(applier.consecutiveFailures == 0)

        writer.failAllSets = true
        // 再失败 limit-1 次也不该禁用（计数已清零，取"连续"语义）
        for _ in 1..<(AXMenubarApplier.consecutiveFailureLimit) { await applier.apply(changes: [change("flaky.item", to: false)]) }
        #expect(!applier.isDisabled)
    }

    @Test func restoreAllNowWritesBackAllAndClearsLedger() async {
        let writer = FakeAXWriter()
        writer.widths["a.item"] = 30
        writer.widths["b.item"] = 24
        let (applier, tracker) = makeApplier(writer: writer)
        await applier.apply(changes: [change("a.item", to: false), change("b.item", to: false)])
        writer.resetCalls()

        await applier.restoreAllNow()
        #expect(writer.setCalls.count == 2)
        #expect(writer.widths["a.item"] == 30)
        #expect(writer.widths["b.item"] == 24)
        #expect(await tracker.currentlyHidden().isEmpty)

        // 账本清空后再次 restoreAllNow 是零操作（幂等）
        writer.resetCalls()
        await applier.restoreAllNow()
        #expect(writer.setCalls.isEmpty)
    }

    // MARK: - 版本门真实接入（MB-04：verifiedMajor=[26]，ProcessInfo 实测门）

    @Test func versionGateAXListAdmits26Rejects27() {
        #expect(VersionGate.axVerifiedMajors == [26])
        #expect(VersionGate.isSupported(osMajor: 26, verified: VersionGate.axVerifiedMajors))
        #expect(!VersionGate.isSupported(osMajor: 27, verified: VersionGate.axVerifiedMajors))
        // ProcessInfo 实测门与显式名单一致（不赌编译期目标版本）
        let hostMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #expect(VersionGate.hostIsSupportedForAX()
            == VersionGate.isSupported(osMajor: hostMajor, verified: [26]))
    }

    @Test func assemblyGatesRealImplementationsOnHostVersion() {
        let enumerator = MenubarTidyAssembly.makeItemEnumerator()
        let applier = MenubarTidyAssembly.makeApplier()
        if VersionGate.hostIsSupportedForAX() {
            #expect(enumerator is StatusItemEnumerator)
            #expect(applier is AXMenubarApplier)
        } else {
            #expect(enumerator is StubMenubarItemEnumerator)  // fail-closed：stub 零 AX 调用
            #expect(applier is NullMenubarTidyApplier)
        }
    }
}
