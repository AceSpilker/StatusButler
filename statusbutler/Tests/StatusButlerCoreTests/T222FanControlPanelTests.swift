import Foundation
import Testing

@testable import StatusButlerCore

// T-222c FanControlPanel 接管状态机：接管→写→退出恢复全链路（假 writer + 假快照）。
// 引擎决策（decide/shouldWrite）已由 FanControlTests 覆盖，这里只验编排：
// markTakenOver 先行、模式写入先于目标转速、失败熔断、睡眠还权/唤醒重应用、
// 面板数据面（RPM/工作点/曲线预览）。CI 无 WindowServer 可跑——不起真面板。

// MARK: - 假件

private final class RecordingFanWriter: FanWriting, @unchecked Sendable {
    struct Call: Equatable {
        var key: String
        var value: Int
    }

    private let lock = NSLock()
    private var storage: [Call] = []
    /// 目标转速写一律失败（驱动熔断路径）；模式写仍成功——失败要精确在写转速上
    var failRPMWrites = false

    var calls: [Call] { lock.withLock { storage } }

    private func record(_ call: Call) {
        lock.withLock { storage.append(call) }
    }

    func write(key: String, value: Int) async -> Bool {
        if failRPMWrites, key != "FS!" { return false }
        record(Call(key: key, value: value))
        return true
    }

    func setMode(_ mode: UInt8) async -> Bool {
        await write(key: "FS!", value: Int(mode))
    }

    func setRPM(_ rpm: Int, fan: Int) async -> Bool {
        await write(key: "F\(fan)Md", value: rpm)
    }

    func restoreSystem() async -> Bool {
        await write(key: "FS!", value: 1)
    }

    func modeCallCount(_ mode: Int) -> Int {
        calls.filter { $0.key == "FS!" && $0.value == mode }.count
    }

    func rpmValues() -> [Int] {
        calls.filter { $0.key.hasSuffix("Md") }.map(\.value)
    }
}

/// 轮询等待（@MainActor 条件闭包——与全局 waitUntil 的 @Sendable 口径分流：
/// 面板/协调器是主隔离对象，条件读必须在主隔离闭包里才不越权）
@MainActor
private func pollUntil(
    timeout: TimeInterval = 5,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - 测试基准
// 曲线 (40,1200)-(80,4000)：斜率 70 RPM/°C；快照 80°C → 目标 4000（钳制域内），
// currentRPM 2000 低于目标 → 只升不降不拦。风扇 min 1200 / max 5500（A5 名义区间）。

@MainActor
@Suite struct T222FanControlPanelTests {

    private var fan: FanReading {
        FanReading(id: 0, minRPM: 1200, maxRPM: 5500, currentRPM: 2000)
    }

    private var curveConfig: FanControlConfig {
        FanControlConfig(
            mode: .curve,
            curve: FanCurve(points: [
                .init(celsius: 40, rpm: 1200),
                .init(celsius: 80, rpm: 4000),
            ])
        )
    }

    private func makePanel(
        config: FanControlConfig? = nil,
        writer: RecordingFanWriter,
        celsius: Double? = 80,
        installed: Bool = true
    ) -> FanControlPanel {
        FanControlPanel(
            config: config ?? curveConfig,
            writer: writer,
            snapshotProvider: { [fan] in
                ThermalSnapshot(
                    fans: [fan],
                    sensors: celsius.map { [SensorReading(key: "TC0P", name: nil, celsius: $0)] } ?? []
                )
            },
            clock: Date.init,
            tickInterval: 0.05,
            probeAvailability: { installed }
        )
    }

    // MARK: - 接管 → 写 → 退出恢复

    @Test func takeoverWritesModeThenTargetAndExitRestores() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer)

        await panel.beginTakeover()
        #expect(panel.isTakenOver, "markTakenOver 后接管徽标亮起")
        #expect(await pollUntil { writer.rpmValues().contains(4000) }, "循环应写曲线目标 4000")
        #expect(writer.modeCallCount(2) >= 1, "接管先写 FS!=02（强制手动）")
        // 首写即达（shouldWrite 首次放行 + 节流拦重复写）：目标只写过 4000
        #expect(writer.rpmValues().allSatisfy { $0 == 4000 })
        // 数据面上浮：当前转速/温度来自快照
        #expect(panel.currentRPM == 2000)
        #expect(panel.currentCelsius == 80)

        let restored = await panel.endTakeover()
        #expect(restored)
        #expect(!panel.isTakenOver)
        #expect(writer.modeCallCount(1) >= 1, "退出必须写 FS!=01 交还系统")
        // 退出后循环停：再等两拍不再新增写
        let countAfterExit = writer.calls.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(writer.calls.count == countAfterExit)
    }

    @Test func takeoverRefusedWithoutHelperAndDegradesHonestly() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer, installed: false)
        await panel.beginTakeover()
        #expect(!panel.isTakenOver, "未安装 helper 不许接管")
        #expect(writer.calls.isEmpty, "未安装时一次写都不发")
        #expect(panel.statusMessage?.contains("需安装 Helper") == true, "诚实降级文案")
        #expect(!panel.isHelperInstalled)
    }

    @Test func switchingToSystemModeReleasesImmediately() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer)
        await panel.beginTakeover()
        #expect(await pollUntil { !writer.rpmValues().isEmpty })

        await panel.setMode(.system)  // 用户点"系统自动"：还权不等下一拍
        #expect(!panel.isTakenOver)
        #expect(writer.modeCallCount(1) >= 1)
        #expect(panel.mode == .system)
    }

    @Test func persistentWriteFailuresAbortTakeoverSafely() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer)
        await panel.beginTakeover()  // FS!=02 成功
        writer.failRPMWrites = true  // 转速通道从现在起坏死

        #expect(await pollUntil(timeout: 8) { !panel.isTakenOver }, "连续失败达阈值应熔断接管")
        #expect(writer.modeCallCount(1) >= 1, "熔断路径必须还权（FS!=01）")
        #expect(writer.rpmValues().isEmpty, "坏死通道下一次转速都写不进")
    }

    @Test func sleepRelinquishesAndWakeReapplies() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer)
        await panel.beginTakeover()
        #expect(await pollUntil { !writer.rpmValues().isEmpty })

        panel.handleSystemSleep()
        #expect(await pollUntil { !panel.isTakenOver }, "睡眠必须先还权")
        #expect(writer.modeCallCount(1) >= 1)

        let modesBefore = writer.modeCallCount(2)
        panel.handleSystemWake()
        #expect(await pollUntil { writer.modeCallCount(2) > modesBefore }, "唤醒后按意图重接管")
        #expect(panel.isTakenOver)
        #expect(await pollUntil { writer.rpmValues().contains(4000) })
        await panel.endTakeover()
    }

    // MARK: - 面板数据面（曲线预览点/工作点/恒速模式）

    @Test func curvePreviewAndWorkingPointExposeForUI() async {
        let writer = RecordingFanWriter()
        let panel = makePanel(writer: writer)
        await panel.beginTakeover()
        #expect(await pollUntil { panel.currentCelsius != nil })

        #expect(panel.curvePreviewPoints?.count == 2)
        #expect(panel.curvePreviewPoints?.first?.celsius == 40)
        // 工作点 = 当前温度 80°C 落在曲线上的钳制目标
        guard let working = panel.workingPoint else {
            Issue.record("工作点应存在（读数+曲线+风扇齐备）")
            return
        }
        #expect(working.celsius == 80)
        #expect(working.rpm == 4000)
        #expect(panel.mode == .curve, "模式徽标数据源")
        await panel.endTakeover()

        // 读数缺席（虚拟机/无传感器形态）：工作点消失而不是停在旧值
        let blind = FanControlPanel(
            config: curveConfig,
            writer: writer,
            snapshotProvider: { ThermalSnapshot(fans: [fan], sensors: []) },
            clock: Date.init,
            tickInterval: 0.05,
            probeAvailability: { true }
        )
        await blind.beginTakeover()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(blind.workingPoint == nil)
        #expect(writer.rpmValues().allSatisfy { $0 == 4000 }, "无温度时引擎判 leaveSystem，零转速写")
        await blind.endTakeover()
    }

    @Test func constantModeWritesClampedConstant() async {
        let writer = RecordingFanWriter()
        var config = FanControlConfig(mode: .constant)
        config.constantRPM = 4200
        let panel = makePanel(config: config, writer: writer)
        await panel.beginTakeover()
        #expect(await pollUntil { writer.rpmValues().contains(4200) }, "恒速写 constantRPM")
        await panel.endTakeover()
    }

    @Test func availabilityRefreshFlipsInstallState() async {
        let writer = RecordingFanWriter()
        let installed = InstallFlagBox()
        let panel = FanControlPanel(
            config: curveConfig,
            writer: writer,
            snapshotProvider: { ThermalSnapshot(fans: [], sensors: []) },
            clock: Date.init,
            tickInterval: 0.05,
            probeAvailability: { installed.value }
        )
        installed.value = false
        await panel.refreshAvailability()
        #expect(!panel.isHelperInstalled)
        installed.value = true
        await panel.refreshAvailability()
        #expect(panel.isHelperInstalled)
    }
}

/// 可变安装态盒（probeAvailability 闭包捕获）
private final class InstallFlagBox: @unchecked Sendable {
    var value = true
}
