import Foundation
import Testing

@testable import StatusButlerCore

// T-202/T-210：组合音量写入器（DDC 路由 + 回读校验回退 + 静音恒系统）与音量步进
// （±10 钳制 + 绑定路由 + 未注入闭包诚实拒绝）。AppleScript 串一律字面断言绝不执行；
// DDC 失败路径用假符号注入（KERN_FAILURE）复现，矩阵前置参数直钉纯函数。

// MARK: - 测试替身

/// 系统落点记录器：观察 RoutedVolumeWriter 的回退/直写行为（替代 AppleScript 执行）
private final class SystemWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [Int] = []

    func record(_ level: Int) {
        lock.lock(); defer { lock.unlock() }
        levels.append(level)
    }

    var snapshot: [Int] {
        lock.lock(); defer { lock.unlock() }
        return levels
    }
}

/// 全量假 base：setVolume/toggleMute 记录；stepVolume 不实现 → 走协议默认
/// 诚实拒绝（既有实现零改动即可编译的证明本体）
private final class RecordingBaseStore: AutomationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func setVolume(level: Int) -> ActionOutcome {
        lock.lock(); defer { lock.unlock() }
        calls.append("setVolume(\(level))")
        return .performed
    }

    func toggleMute() -> ActionOutcome {
        lock.lock(); defer { lock.unlock() }
        calls.append("toggleMute")
        return .performed
    }

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

/// 线程安全档位箱：@Sendable 读/写闭包共享的可变当前档位（测试替身，锁内收敛）
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Int

    init(_ level: Int) { self.level = level }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    func set(_ newLevel: Int) {
        lock.lock(); defer { lock.unlock() }
        level = newLevel
    }
}

/// I2C 全失败的假符号表（create 必成功以穿过枚举，读写恒 KERN_FAILURE）
private func failingI2CSymbols() -> IOAVServiceSymbols {
    IOAVServiceSymbols(
        create: { _ in OpaquePointer(bitPattern: 1) },
        readI2C: { _, _, _, _, _ in KERN_FAILURE },
        writeI2C: { _, _, _, _, _ in KERN_FAILURE },
        release: { _ in }
    )
}

// MARK: - T-202 组合写入器

@Suite struct RoutedVolumeWriterTests {

    // MARK: AppleScript 串字面（不执行）

    @Test func systemScriptLiteralsArePinned() {
        // 串面 = `set volume` 公开口径；越界档位先钳再生成
        #expect(DisplayVolumeScript.outputVolumeScript(for: 42) == "set volume output volume 42")
        #expect(DisplayVolumeScript.outputVolumeScript(for: 150) == "set volume output volume 100")
        #expect(DisplayVolumeScript.outputVolumeScript(for: -7) == "set volume output volume 0")
        #expect(DisplayVolumeScript.toggleMuteScript == "set volume output muted (not (output muted))")
    }

    // MARK: 决策与回退矩阵（纯函数直钉）

    @Test func fallbackMatrixCoversAllFailureSurfaces() {
        // 前置失败：客户端缺位 / 枚举不到外接屏
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: false, displayFound: false, writeSucceeded: true, readBack: 50, expected: 50
        ) == .fallback(.ddcClientMissing))
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: false, writeSucceeded: true, readBack: 50, expected: 50
        ) == .fallback(.displayNotFound))
        // I2C 写失败（回读无论给什么都不再翻案）
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: false, readBack: 50, expected: 50
        ) == .fallback(.writeRejected))
        // 回读 nil（两段式读值失败）→ verifyFailed 携带 nil
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: nil, expected: 50
        ) == .fallback(.verifyFailed(readBack: nil, expected: 50)))
        // 全绿 → applied
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 50, expected: 50
        ) == .applied)
    }

    @Test func readBackToleranceAbsorbsQuantizationButNotRealFailures() {
        // 容差 2：MCCS 满量程不一的量化噪声放行（差 1-2 档），真失败拦下（差 3+）
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 82, expected: 80
        ) == .applied)
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 78, expected: 80
        ) == .applied)
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 83, expected: 80
        ) == .fallback(.verifyFailed(readBack: 83, expected: 80)))
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 8, expected: 80
        ) == .fallback(.verifyFailed(readBack: 8, expected: 80)))
        // 注入容差覆盖同样生效（0 容差 = 精确匹配）
        #expect(RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true, writeSucceeded: true, readBack: 81, expected: 80, tolerance: 0
        ) == .fallback(.verifyFailed(readBack: 81, expected: 80)))
    }

    @Test func muteDecisionIsPinnedToSystemRegardlessOfRoute() {
        // 决策钉死：各家 DDC 静音寄存器（MCCS 0x8C）实现不一，误写修不回来；
        // 系统对 HDMI/DP 音频做软件静音同样生效 → 恒系统
        #expect(RoutedVolumeDecision.muteAlwaysUsesSystem())
    }

    // MARK: 写路径（注入系统落点观察）

    @Test func systemRouteWritesThroughSystemChannelWithoutDegrading() async {
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: DDCClient(symbols: failingI2CSymbols()),
            routeDecision: { .system },
            currentVolume: { 33 },
            systemWrite: { await Task.yield(); recorder.record($0) }
        )
        // .system 路由对 DDC 通道完全不触碰（哪怕符号表是坏的）
        await writer.write(level: 42)
        #expect(recorder.snapshot == [42])
        #expect(writer.ddcFallbackCount == 0)
    }

    @Test func systemRouteClampsOutOfRangeLevels() async {
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: nil, routeDecision: { .system }, currentVolume: { 0 },
            systemWrite: { recorder.record($0) }
        )
        await writer.write(level: 150)
        await writer.write(level: -3)
        #expect(recorder.snapshot == [100, 0])
    }

    @Test func missingDDCClientOnDDCRouteFallsBackAndCounts() async {
        // 路由判了 .ddc 但客户端缺位（组合根注入 nil）→ 回退系统 + 记降级一次
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: nil, routeDecision: { .ddc }, currentVolume: { 10 },
            systemWrite: { recorder.record($0) }
        )
        await writer.write(level: 55)
        #expect(recorder.snapshot == [55])
        #expect(writer.ddcFallbackCount == 1)
    }

    @Test func nilSymbolsDegradeDDCRoutesToSystem() async {
        // dlsym 失败的等价注入：isAvailable=false 场景下路由即便硬指 .ddc，
        // 枚举空 → displayNotFound 回退（fail-safe 纵深：路由与通道各自独立兜底）
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: DDCClient(symbols: nil), routeDecision: { .ddc }, currentVolume: { 10 },
            systemWrite: { recorder.record($0) }
        )
        await writer.write(level: 50)
        #expect(recorder.snapshot == [50])
        #expect(writer.ddcFallbackCount == 1)
    }

    @Test func failingI2CPipelineFallsBackToSystemOncePerWrite() async {
        // create 成功但 I2C 全失败：写失败短路（不发读请求）→ writeRejected 回退。
        // 本机有屏/无屏都成立（枚举空走 displayNotFound，同为回退），CI 无 IOKit 环境不敏感
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: DDCClient(symbols: failingI2CSymbols()),
            routeDecision: { .ddc }, currentVolume: { 10 },
            systemWrite: { recorder.record($0) }
        )
        await writer.write(level: 70)
        await writer.write(level: 80)
        #expect(recorder.snapshot == [70, 80])
        #expect(writer.ddcFallbackCount == 2)
    }

    @Test func degradeCounterIsSharedAcrossStructCopies() async {
        // 值类型拷贝共享降级历史：同一写入器经协议 existential 拷贝后仍累计
        let recorder = SystemWriteRecorder()
        let writer = RoutedVolumeWriter(
            ddc: nil, routeDecision: { .ddc }, currentVolume: { 0 },
            systemWrite: { recorder.record($0) }
        )
        let copied: any VolumeWriting = writer
        await copied.write(level: 20)
        #expect(writer.ddcFallbackCount == 1)
    }

    // MARK: 读回与工厂

    @Test func readCurrentLevelPrefersDDCButFailsSafeToInjectedReader() {
        // .ddc 但通道缺位 → 回退注入读闭包（面板乐观显示的初值来源）
        let writer = RoutedVolumeWriter(ddc: nil, routeDecision: { .ddc }, currentVolume: { 33 })
        #expect(writer.readCurrentLevel() == 33)
        // .system 恒注入闭包
        let systemWriter = RoutedVolumeWriter(
            ddc: DDCClient(symbols: nil), routeDecision: { .system }, currentVolume: { 66 }
        )
        #expect(systemWriter.readCurrentLevel() == 66)
    }

    @Test func liveRouteClosureEvaluatesToAValidRoute() {
        // live 工厂只验"可求值且值域合法"——具体落点随默认输出设备漂移，
        // 路由决策表已在 DDCVolumeTests 直钉，此处不复验硬件
        let route = RoutedVolumeWriter.liveRoute()
        let first = route()
        #expect(first == .system || first == .ddc)
    }
}

// MARK: - T-210 音量步进

@Suite struct VolumeSteppingTests {

    @Test func steppedLevelClampsAtBothEnds() {
        #expect(VolumeStepping.steppedLevel(current: 50, delta: 10) == 60)
        #expect(VolumeStepping.steppedLevel(current: 50, delta: -10) == 40)
        // 边界钳制：上探/下探收敛端点，不环绕不拒绝
        #expect(VolumeStepping.steppedLevel(current: 95, delta: 10) == 100)
        #expect(VolumeStepping.steppedLevel(current: 5, delta: -10) == 0)
        #expect(VolumeStepping.steppedLevel(current: 0, delta: -10) == 0)
        #expect(VolumeStepping.steppedLevel(current: 100, delta: 10) == 100)
        // 超步幅 delta 同样只钳不拒（写入域统一收 0-100）
        #expect(VolumeStepping.steppedLevel(current: 42, delta: -100) == 0)
    }

    @Test func defaultStepMatchesPanelSliderTenFoldFeel() {
        #expect(VolumeStepping.defaultStep == 10)
    }

    @Test func steppingStoreWiresInjectedReaderAndWriter() {
        // 闭包注入型实现：current + delta 钳制后过 writer，结果原样上抛
        let writerCalls = SystemWriteRecorder()
        let current = LevelBox(42)
        let store = SteppingVolumeStore(
            currentVolume: { current.value },
            writeLevel: { level in writerCalls.record(level); current.set(level); return .performed },
            base: RecordingBaseStore()
        )
        #expect(store.stepVolume(delta: 10) == .performed)
        #expect(store.stepVolume(delta: 10) == .performed)
        #expect(store.stepVolume(delta: 10) == .performed)
        #expect(store.stepVolume(delta: -25) == .performed)
        // 42 → 52 → 62 → 72 → 47：链式读改写
        #expect(writerCalls.snapshot == [52, 62, 72, 47])
    }

    @Test func steppingStoreDelegatesBaseOperationsUntouched() {
        let base = RecordingBaseStore()
        let store = SteppingVolumeStore(
            currentVolume: { 10 }, writeLevel: { _ in .performed }, base: base
        )
        #expect(store.setVolume(level: 30) == .performed)
        #expect(store.toggleMute() == .performed)
        #expect(base.snapshot == ["setVolume(30)", "toggleMute"])
    }

    @Test func uninjectedSteppingRejectsHonestlyWithoutTouchingBase() {
        // 协议默认实现 = "未注入闭包"的诚实拒绝：既有 AutomationStore 实现零改动
        // 即可编译（App/SystemStore 不改也 build），运行时诚实说缺接线
        let base = RecordingBaseStore()
        guard case .rejected(let reason) = base.stepVolume(delta: 10) else {
            Issue.record("未注入闭包的默认 stepVolume 应拒绝")
            return
        }
        #expect(reason.contains("步进"))
        #expect(reason.contains("闭包"))
        #expect(base.snapshot.isEmpty)  // setVolume/toggleMute 未被顺手代跑
    }

    @Test func bindingsRouteVolumeUpDownThroughStepVolume() {
        // volume/up、volume/down 绑定改走 stepVolume(±10)：走注入闭包时端到端 performed，
        // 且步进只经 stepVolume 通道（base 的 setVolume 不被代跑）
        let writerCalls = SystemWriteRecorder()
        let current = LevelBox(95)
        let store = SteppingVolumeStore(
            currentVolume: { current.value },
            writeLevel: { level in writerCalls.record(level); current.set(level); return .performed },
            base: RecordingBaseStore()
        )
        let bindings = AutomationGlue.executorBindings(store: store)
        #expect(bindings["volume"]?(ButlerCommand(verb: "volume/up")) == .performed)
        #expect(writerCalls.snapshot == [100])  // 95 + 10 钳 100
        current.set(5)
        #expect(bindings["volume"]?(ButlerCommand(verb: "volume/down")) == .performed)
        #expect(writerCalls.snapshot == [100, 0])  // 5 - 10 钳 0
    }

    @Test func bindingsWithUninjectedStoreKeepHonestRejection() {
        // 组合根没接步进闭包（默认实现）时，up/down 绑定如实拒绝并说明缺口
        let store = RecordingBaseStore()
        let bindings = AutomationGlue.executorBindings(store: store)
        guard case .rejected(let upReason) = bindings["volume"]?(ButlerCommand(verb: "volume/up")) else {
            Issue.record("未注入闭包时 volume/up 应拒绝")
            return
        }
        #expect(upReason.contains("步进"))
        guard case .rejected(let downReason) = bindings["volume"]?(ButlerCommand(verb: "volume/down")) else {
            Issue.record("未注入闭包时 volume/down 应拒绝")
            return
        }
        #expect(downReason.contains("步进"))
        #expect(store.snapshot.isEmpty)
    }
}
