import Foundation
import Testing
@testable import StatusButlerCore

// A14-ε（E8 · IC-01~04）：LWW 三情形 / 关闭态零云调用 / 冲突人工裁决 / 静默降级。
// 全部走假 store——真实 CloudKit 依赖 entitlement/账号，不进单测（IC-04 的降级路径
// 恰恰要在"云不可用"时验证，假 store 抛错即可模拟）。

/// 假云端：actor 保证 Sendable + 计数线程安全；seed/throwError 是测试摆态出口
actor FakeCloudStore: CloudStoring {
    private var record: CloudSettingsRecord?
    private(set) var saveCount = 0
    private(set) var loadCount = 0
    private var thrownError: Error?

    init() {}

    func seed(_ record: CloudSettingsRecord?) { self.record = record }
    func throwError(_ error: Error?) { self.thrownError = error }

    func save(_ record: CloudSettingsRecord) async throws {
        if let thrownError { throw thrownError }
        saveCount += 1
        self.record = record
    }

    func load() async throws -> CloudSettingsRecord? {
        if let thrownError { throw thrownError }
        loadCount += 1
        return record
    }
}

/// 已应用远端记录的收集盒：@MainActor 测试 + @MainActor 闭包内触碰，
//  Sendable 标注只为满足闭包捕获检查（隔离域单一）
final class AppliedBox: @unchecked Sendable {
    private(set) var records: [CloudSettingsRecord] = []
    func append(_ record: CloudSettingsRecord) { records.append(record) }
}

@MainActor
@Suite struct CloudSyncTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ offset: TimeInterval, device: String = "MacBook") -> CloudSettingsRecord {
        CloudSettingsRecord(
            settingsJSON: Data("{\"iconSize\":18}".utf8),
            themeJSON: Data("{\"schemaVersion\":1}".utf8),
            modified: base.addingTimeInterval(offset),
            deviceName: device
        )
    }

    private func makeCoordinator(
        store: FakeCloudStore,
        local: CloudSettingsRecord?,
        applied: AppliedBox
    ) -> SyncCoordinator {
        SyncCoordinator(
            store: store,
            localSnapshot: { local },
            applyRemote: { applied.append($0) }
        )
    }

    // MARK: - LWW 三情形

    @Test func lwwLocalNewerPushesAndSaves() async {
        let store = FakeCloudStore()
        await store.seed(record(-60, device: "iMac"))  // 远端早 60 秒
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)

        let outcome = await coordinator.syncNow()
        #expect(outcome == .pushed)
        #expect(await store.saveCount == 1)
        #expect(applied.records.isEmpty)
    }

    @Test func lwwRemoteNewerPullsAndApplies() async {
        let store = FakeCloudStore()
        let remote = record(120, device: "Mac mini")  // 远端晚 120 秒
        await store.seed(remote)
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)

        let outcome = await coordinator.syncNow()
        #expect(outcome == .pulled)
        #expect(await store.saveCount == 0)  // 下行不动云端
        #expect(applied.records == [remote])
    }

    @Test func lwwEqualTimestampsSurfacesManualConflict() async {
        let store = FakeCloudStore()
        let remote = record(0, device: "Mac mini")  // 与本地同刻
        await store.seed(remote)
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)

        let outcome = await coordinator.syncNow()
        #expect(outcome == .conflict(.manual(local: record(0), remote: remote)))
        #expect(await store.saveCount == 0)  // 裁决前不写任何一侧
        #expect(applied.records.isEmpty)
        // 待决账已挂上（设置页消费）：双方设备名可展示（IC-03）
        #expect(coordinator.pendingConflict?.local.deviceName == "MacBook")
        #expect(coordinator.pendingConflict?.remote.deviceName == "Mac mini")
    }

    @Test func resolvePureFunctionCoversNilRemoteAndStrictInequality() {
        let local = record(0)
        #expect(SyncCoordinator.resolve(local: local, remote: nil) == .pushed)  // 云端空：直接上行
        #expect(SyncCoordinator.resolve(local: local, remote: record(-1)) == .pushed)
        #expect(SyncCoordinator.resolve(local: local, remote: record(1)) == .pulled)
        #expect(SyncCoordinator.resolve(local: local, remote: record(0, device: "X"))
            == .conflict(.manual(local: local, remote: record(0, device: "X"))))
    }

    // MARK: - 关闭态零云调用（IC-04 可测试契约）

    @Test func disabledMakesZeroCloudCalls() async {
        let store = FakeCloudStore()
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        // 默认 isEnabled = false，不调 setEnabled
        let outcome = await coordinator.syncNow()
        guard case .failed(let reason) = outcome else {
            Issue.record("关闭态应返回 failed，得到 \(outcome)")
            return
        }
        #expect(reason.contains("未开启"))
        #expect(await store.loadCount == 0)
        #expect(await store.saveCount == 0)
        // 人工裁决同样被关闭态拦截（不碰云）
        let settle = await coordinator.settleConflict(winner: .localWins)
        guard case .failed(let settleReason) = settle else {
            Issue.record("关闭态裁决应返回 failed，得到 \(settle)")
            return
        }
        #expect(settleReason.contains("未开启"))
        #expect(await store.saveCount == 0)
    }

    @Test func emptyCloudPushesFirstSnapshot() async {
        let store = FakeCloudStore()  // 不 seed：云端无记录
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)
        #expect(await coordinator.syncNow() == .pushed)
        #expect(await store.saveCount == 1)
    }

    @Test func missingLocalSnapshotFailsHonestly() async {
        let store = FakeCloudStore()
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: nil, applied: applied)
        coordinator.setEnabled(true)
        let outcome = await coordinator.syncNow()
        guard case .failed(let reason) = outcome else {
            Issue.record("应失败，得到 \(outcome)")
            return
        }
        #expect(reason.contains("快照"))
        #expect(await store.loadCount == 0)  // 本地都没打包好，不该先打云
    }

    // MARK: - 静默降级（IC-04）

    @Test func cloudFailureDegradesToLocalModeWithoutDataMovement() async {
        let store = FakeCloudStore()
        await store.throwError(URLError(.notConnectedToInternet))
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)

        let outcome = await coordinator.syncNow()
        guard case .failed(let reason) = outcome else {
            Issue.record("云故障应返回 failed，得到 \(outcome)")
            return
        }
        #expect(reason.contains("CloudKit"))
        #expect(applied.records.isEmpty)  // 本地零损失
        #expect(coordinator.phase == .idle)  // 状态机复位（不卡 syncing）
    }

    // MARK: - 冲突人工裁决出口

    @Test func settleConflictLocalWinsPushesLocal() async {
        let store = FakeCloudStore()
        await store.seed(record(0, device: "Mac mini"))
        let applied = AppliedBox()
        let local = record(0)
        let coordinator = makeCoordinator(store: store, local: local, applied: applied)
        coordinator.setEnabled(true)
        _ = await coordinator.syncNow()  // 制造同刻冲突
        #expect(coordinator.pendingConflict != nil)

        let outcome = await coordinator.settleConflict(winner: .localWins)
        #expect(outcome == .pushed)
        #expect(await store.saveCount == 1)
        #expect(applied.records.isEmpty)  // 本地胜出不下行
        #expect(coordinator.pendingConflict == nil)  // 待决账清空
    }

    @Test func settleConflictRemoteWinsAppliesRemoteWithoutResaving() async {
        let store = FakeCloudStore()
        let remote = record(0, device: "Mac mini")
        await store.seed(remote)
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)
        _ = await coordinator.syncNow()

        let outcome = await coordinator.settleConflict(winner: .remoteWins)
        #expect(outcome == .pulled)
        #expect(applied.records == [remote])  // 下行应用
        #expect(await store.saveCount == 0)  // 云端本就是胜出份，不回写挑下一轮撞车
        #expect(coordinator.pendingConflict == nil)
    }

    @Test func settleConflictRejectsManualAndWithoutPending() async {
        let store = FakeCloudStore()
        let applied = AppliedBox()
        let coordinator = makeCoordinator(store: store, local: record(0), applied: applied)
        coordinator.setEnabled(true)
        // 无待决冲突
        let noPending = await coordinator.settleConflict(winner: .localWins)
        #expect(noPending == .failed("当前无待裁决冲突"))
        // manual 不是合法裁决（二选一才是）
        await store.seed(record(0, device: "X"))
        _ = await coordinator.syncNow()
        let manual = await coordinator.settleConflict(winner: .manual(local: record(0), remote: record(0, device: "X")))
        #expect(manual == .failed("人工裁决只接受 localWins 或 remoteWins"))
        #expect(await store.saveCount == 0)
    }

    // MARK: - CloudKit 契约钉死（entitlement/Console 对齐用）

    @Test func cloudKitContractIdentifiersArePinned() {
        #expect(CloudKitStore.recordType == "SettingsSnapshot")
        #expect(CloudKitStore.recordName == "current")
        #expect(CloudKitStore.containerIdentifier == "iCloud.com.linzhongyang.statusbutler")
    }
}
