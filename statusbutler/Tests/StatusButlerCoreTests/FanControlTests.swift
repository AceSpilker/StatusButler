import Foundation
import Testing
@testable import StatusButlerCore

// T-026: 风扇曲线引擎+安全护栏纯逻辑层
// 固定基准读数：fan 一律 min 1200 / max 5500 / current 2000（A5 名义区间），
// 曲线取手工可验算的两点线（70 RPM/°C）与带平台拐点的折线
@Suite struct FanControlTests {
    private let fan = FanReading(id: 0, minRPM: 1200, maxRPM: 5500, currentRPM: 2000)

    /// 两点线 (40,1200)-(80,4000)：斜率 70 RPM/°C，插值/端点/钳制的验算基准
    private let twoPoint = FanCurve(points: [
        .init(celsius: 40, rpm: 1200),
        .init(celsius: 80, rpm: 4000),
    ])

    /// 平台拐点折线：70°C 前贴 1200，之上 190 RPM/°C——滞回防锯齿的验算基准
    private let knee = FanCurve(points: [
        .init(celsius: 50, rpm: 1200),
        .init(celsius: 70, rpm: 1200),
        .init(celsius: 90, rpm: 5000),
    ])

    // MARK: - 曲线插值

    @Test func twoPointCurveInterpolatesLinearly() {
        #expect(twoPoint.rpm(forCelsius: 40) == 1200)
        #expect(twoPoint.rpm(forCelsius: 50) == 1900)
        #expect(twoPoint.rpm(forCelsius: 60) == 2600)
        #expect(twoPoint.rpm(forCelsius: 79.5) == 3965)  // 1200 + 39.5×70
        #expect(twoPoint.rpm(forCelsius: 80) == 4000)
    }

    @Test func multiPointCurveInterpolatesPerSegment() {
        // quiet 各段中点：(35,1200)-(60,1300)-(75,1800)-(90,3200)-(105,5500)
        #expect(FanCurve.quiet.rpm(forCelsius: 47.5) == 1250)
        #expect(FanCurve.quiet.rpm(forCelsius: 67.5) == 1550)
        #expect(FanCurve.quiet.rpm(forCelsius: 82.5) == 2500)
        #expect(FanCurve.quiet.rpm(forCelsius: 97.5) == 4350)
        #expect(FanCurve.balanced.rpm(forCelsius: 57.5) == 1850)
    }

    @Test func outsideDomainTakesEndpointRPM() {
        #expect(twoPoint.rpm(forCelsius: 20) == 1200)
        #expect(twoPoint.rpm(forCelsius: 39.99) == 1200)
        #expect(twoPoint.rpm(forCelsius: 80.01) == 4000)
        #expect(twoPoint.rpm(forCelsius: 200) == 4000)
        #expect(FanCurve.quiet.rpm(forCelsius: 0) == 1200)
        #expect(FanCurve.quiet.rpm(forCelsius: 300) == 5500)
    }

    @Test func degenerateAndUnsortedCurvesAreNormalized() {
        // 少于 2 点构不成折线：单点恒定、空曲线退 0 交由钳制兜底
        #expect(FanCurve(points: [.init(celsius: 50, rpm: 3000)]).rpm(forCelsius: 99) == 3000)
        #expect(FanCurve(points: []).rpm(forCelsius: 60) == 0)
        // 乱序点构造即归一化：与手工排序版相等，插值结果一致
        let unsorted = FanCurve(points: [
            .init(celsius: 80, rpm: 4000),
            .init(celsius: 40, rpm: 1200),
        ])
        #expect(unsorted == twoPoint)
        #expect(unsorted.rpm(forCelsius: 60) == 2600)
    }

    // MARK: - 厂商区间钳制

    @Test func clampingPinsToVendorRange() {
        let jagged = FanCurve(points: [
            .init(celsius: 40, rpm: 1000),
            .init(celsius: 80, rpm: 6000),
        ])
        #expect(jagged.rpm(forCelsius: 40) == 1000)  // 钳制前裸值可越界
        #expect(jagged.rpmClamped(forCelsius: 40, min: 1200, max: 5500) == 1200)
        #expect(jagged.rpmClamped(forCelsius: 80, min: 1200, max: 5500) == 5500)
        #expect(jagged.rpmClamped(forCelsius: 60, min: 1200, max: 5500) == 3500)  // 段内原样通过
    }

    // MARK: - 滞回双曲线（升温主曲线 / 降温低曲线）

    @Test func hysteresisRisingUsesMainCurve() {
        // 首次求值（无记忆）= 主曲线
        #expect(FanCurve.rpm(forCelsius: 60, curve: twoPoint, min: 1200, max: 5500, hysteresis: HysteresisState()) == 2600)
        // 目标高于上次施加值 ⇒ 升温路径，直接走主曲线（不吃 +band 抬升）
        let rising = HysteresisState(lastAppliedRPM: 2600)
        #expect(FanCurve.rpm(forCelsius: 62, curve: twoPoint, min: 1200, max: 5500, hysteresis: rising) == 2740)
        #expect(FanCurve.rpm(forCelsius: 63, curve: twoPoint, min: 1200, max: 5500, hysteresis: rising) == 2810)
    }

    @Test func hysteresisFallingHoldsThenLags() {
        let falling = HysteresisState(lastAppliedRPM: 2600)  // 上次 60°C 施加 2600
        // 温度回落但未耗尽带宽：保持上次施加值，而不是主曲线的 2460
        #expect(FanCurve.rpm(forCelsius: 58, curve: twoPoint, min: 1200, max: 5500, hysteresis: falling) == 2600)
        // 降温路径绝不高于上次施加值（不向上爬齿）
        #expect(FanCurve.rpm(forCelsius: 59.9, curve: twoPoint, min: 1200, max: 5500, hysteresis: falling) == 2600)
        // 温度跌过带宽：沿低曲线（T+band 求值）释放——C(53)=2110
        #expect(FanCurve.rpm(forCelsius: 50, curve: twoPoint, min: 1200, max: 5500, hysteresis: falling) == 2110)
    }

    @Test func hysteresisAbsorbsThresholdSawtooth() {
        // 拐点 70°C 附近抖动：无滞回会 1200↔1390 来回打齿；带 3°C 滞回整个吸收
        var state = HysteresisState()
        var target = FanCurve.rpm(forCelsius: 70, curve: knee, min: 1200, max: 5500, hysteresis: state)
        #expect(target == 1200)
        state.lastAppliedRPM = target

        target = FanCurve.rpm(forCelsius: 71, curve: knee, min: 1200, max: 5500, hysteresis: state)
        #expect(target == 1390)  // 升温越拐点 → 上台阶
        state.lastAppliedRPM = target

        // 回落到拐点上、下抖动：保持 1390 不下台阶（主曲线裸值 1200/1295）
        target = FanCurve.rpm(forCelsius: 70, curve: knee, min: 1200, max: 5500, hysteresis: state)
        #expect(target == 1390)
        target = FanCurve.rpm(forCelsius: 70.5, curve: knee, min: 1200, max: 5500, hysteresis: state)
        #expect(target == 1390)

        // 温度真降过带宽（70-3）：才沿低曲线释放回平台
        target = FanCurve.rpm(forCelsius: 67, curve: knee, min: 1200, max: 5500, hysteresis: state)
        #expect(target == 1200)
    }

    // MARK: - 三模式决定器

    @Test func systemModeAlwaysLeavesSystemAndClearsState() {
        var state = HysteresisState(lastAppliedRPM: 2600)
        let decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .system), celsius: 60, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
        #expect(state.lastAppliedRPM == nil)  // 交还系统后滞回记忆作废
    }

    @Test func constantModeClampsAndSets() {
        var state = HysteresisState()
        // 越上限钳到厂商 max
        var decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .constant, constantRPM: 6000),
            celsius: nil, fan: fan, state: &state)
        #expect(decision == .setRPM(5500))
        #expect(state.lastAppliedRPM == 5500)
        // 区间内原样
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .constant, constantRPM: 3000),
            celsius: nil, fan: fan, state: &state)
        #expect(decision == .setRPM(3000))
        // 缺目标值不猜
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .constant), celsius: nil, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
    }

    @Test func curveModeDecidesFromTemperature() {
        var state = HysteresisState()
        var decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: twoPoint),
            celsius: 60, fan: fan, state: &state)
        #expect(decision == .setRPM(2600))
        #expect(state.lastAppliedRPM == 2600)
        // 温度源缺失 / 曲线缺失 / 不足 2 点：全部交还系统
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: twoPoint),
            celsius: nil, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve), celsius: 60, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: FanCurve(points: [.init(celsius: 50, rpm: 2000)])),
            celsius: 60, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
    }

    @Test func onlyRaiseAboveSystemYieldsToLowerSystemSpeed() {
        // 曲线目标 1550（45°C）低于系统当前 2000：只升不降 → 让系统继续
        var state = HysteresisState(lastAppliedRPM: 2600)
        var decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: twoPoint),
            celsius: 45, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
        #expect(state.lastAppliedRPM == 2600)  // leaveSystem 不动滞回记忆
        // 关掉开关：允许压低。此刻滞回记忆还在（2600），走降温低曲线 C(45+3)=1760
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: twoPoint, onlyRaiseAboveSystem: false),
            celsius: 45, fan: fan, state: &state)
        #expect(decision == .setRPM(1760))
        // 无滞回记忆时直接走主曲线 1550
        var fresh = HysteresisState()
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .curve, curve: twoPoint, onlyRaiseAboveSystem: false),
            celsius: 45, fan: fan, state: &fresh)
        #expect(decision == .setRPM(1550))
        // 恒速模式同理：800 钳到 1200 仍低于 2000 → leaveSystem
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .constant, constantRPM: 800),
            celsius: nil, fan: fan, state: &state)
        #expect(decision == .leaveSystem)
        decision = FanControlEngine.decide(
            config: FanControlConfig(mode: .constant, constantRPM: 800, onlyRaiseAboveSystem: false),
            celsius: nil, fan: fan, state: &state)
        #expect(decision == .setRPM(1200))
    }

    @Test func implausibleTemperatureNeverDrivesWrites() {
        // A5·TF-01 故障哨兵与离谱读数：不驱动任何写入（含关掉只升不降的场景）
        let config = FanControlConfig(mode: .curve, curve: twoPoint, onlyRaiseAboveSystem: false)
        var state = HysteresisState()
        for bad in [-127.0, 200.0, .nan] {
            #expect(FanControlEngine.decide(config: config, celsius: bad, fan: fan, state: &state) == .leaveSystem)
        }
    }

    // MARK: - 写节流（A5·TF-22：≥2s 或变化 >200 RPM）

    @Test func firstWriteAlwaysGoesThrough() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 首写不受任何节流约束（哪怕刚写过的假象时钟）
        #expect(FanControlEngine.shouldWrite(
            previous: nil, next: .setRPM(2600),
            lastWriteAt: now.addingTimeInterval(-0.1), now: now))
    }

    @Test func unchangedDecisionWritesNothing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!FanControlEngine.shouldWrite(
            previous: .setRPM(2600), next: .setRPM(2600),
            lastWriteAt: now.addingTimeInterval(-10), now: now))
        #expect(!FanControlEngine.shouldWrite(
            previous: .leaveSystem, next: .leaveSystem, lastWriteAt: nil, now: now))
    }

    @Test func throttledWhenIntervalAndDeltaBothTooSmall() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 间隔 1s < 2s 且 Δ100 < 200：两条路都不满足 → 不写
        #expect(!FanControlEngine.shouldWrite(
            previous: .setRPM(3000), next: .setRPM(3100),
            lastWriteAt: now.addingTimeInterval(-1), now: now))
    }

    @Test func significantDeltaBypassesInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 间隔不足但 Δ400 > 200：显著变化立即写（TF-22 的"或"语义）
        #expect(FanControlEngine.shouldWrite(
            previous: .setRPM(3000), next: .setRPM(3400),
            lastWriteAt: now.addingTimeInterval(-0.5), now: now))
    }

    @Test func elapsedIntervalAllowsSmallDelta() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Δ100 不显著但间隔已满 2s：跟得上设定
        #expect(FanControlEngine.shouldWrite(
            previous: .setRPM(3000), next: .setRPM(3100),
            lastWriteAt: now.addingTimeInterval(-2), now: now))
        // 差一秒都不行（≥ 2s 是下限）
        #expect(!FanControlEngine.shouldWrite(
            previous: .setRPM(3000), next: .setRPM(3100),
            lastWriteAt: now.addingTimeInterval(-1.99), now: now))
    }

    @Test func restoringSystemIsNeverThrottled() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 恢复系统自动模式是安全关键转换：哪怕刚写完也放行
        #expect(FanControlEngine.shouldWrite(
            previous: .setRPM(3000), next: .leaveSystem,
            lastWriteAt: now.addingTimeInterval(-0.1), now: now))
        // 交还系统后的首次设定视为全量变化，同样不受节流
        #expect(FanControlEngine.shouldWrite(
            previous: .leaveSystem, next: .setRPM(1250),
            lastWriteAt: now.addingTimeInterval(-0.1), now: now))
    }

    // MARK: - 预设曲线有效性

    @Test func presetsStayInsideNominalRange() {
        for preset in [FanCurve.quiet, .balanced, .performance, .fullSpeed] {
            #expect(preset.points.count >= 2)
            for pair in zip(preset.points, preset.points.dropFirst()) {
                #expect(pair.0.celsius < pair.1.celsius)  // 横坐标严格升序
                #expect(pair.0.rpm <= pair.1.rpm)  // 转速单调不降（防"越热越慢"脏曲线）
            }
            for point in preset.points {
                #expect(point.rpm >= 1200 && point.rpm <= 5500)  // 名义厂商区间内
                #expect(point.celsius >= 30 && point.celsius <= 110)  // TF-21 编辑器横轴域
            }
            #expect(preset.points.last?.rpm == 5500)  // 顶点必达上限：极热不压制散热
        }
    }

    @Test func presetEndpointsBehaveAsDesigned() {
        #expect(FanCurve.quiet.rpm(forCelsius: 25) == 1200)  // 冷态贴下限近无声
        #expect(FanCurve.quiet.rpm(forCelsius: 105) == 5500)
        #expect(FanCurve.balanced.rpm(forCelsius: 35) == 1300)
        for t in [30.0, 70.0, 110.0] {
            #expect(FanCurve.fullSpeed.rpm(forCelsius: t) == 5500)
        }
    }

    // MARK: - 接管自愈状态机

    @Test func takeoverTrackerTransitions() {
        let at = Date(timeIntervalSince1970: 500)
        var tracker = TakeoverTracker()
        #expect(tracker.shouldRestoreOnLaunch(persistedTakeover: nil) == false)
        #expect(tracker.shouldRestoreOnLaunch(persistedTakeover: TakeoverTracker()) == false)

        tracker.markTakenOver(at: at)
        #expect(tracker.isTakenOver)
        #expect(tracker.takeoverAt == at)
        // 本会话已接管：不算异常退出自愈
        #expect(tracker.shouldRestoreOnLaunch(persistedTakeover: TakeoverTracker(isTakenOver: true, takeoverAt: at)) == false)

        // 全新会话 + 磁盘残留接管标记 = 上次异常退出 → 需要启动自愈
        #expect(TakeoverTracker().shouldRestoreOnLaunch(persistedTakeover: tracker))

        tracker.relinquish()
        #expect(!tracker.isTakenOver)
        #expect(tracker.takeoverAt == nil)
        #expect(TakeoverTracker().shouldRestoreOnLaunch(persistedTakeover: tracker) == false)
    }

    // MARK: - 持久化编解码

    @Test func codableRoundTripsPreserveSemantics() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let curveData = try encoder.encode(twoPoint)
        #expect(try decoder.decode(FanCurve.self, from: curveData) == twoPoint)

        // 手改 JSON 的乱序点解码后同样归一化
        let unsortedJSON = #"{"points":[{"celsius":80,"rpm":4000},{"celsius":40,"rpm":1200}]}"#
        #expect(try decoder.decode(FanCurve.self, from: Data(unsortedJSON.utf8)) == twoPoint)

        var state = HysteresisState()
        let config = FanControlConfig(
            mode: .curve, constantRPM: 2500, curve: twoPoint,
            onlyRaiseAboveSystem: false, hysteresisBand: 2.5)
        _ = FanControlEngine.decide(config: config, celsius: 60, fan: fan, state: &state)
        let configData = try encoder.encode(config)
        #expect(try decoder.decode(FanControlConfig.self, from: configData) == config)
        let stateData = try encoder.encode(state)
        #expect(try decoder.decode(HysteresisState.self, from: stateData) == HysteresisState(lastAppliedRPM: 2600))
    }

    @Test func fanModeRawValuesAreFrozen() {
        // rawValue 是磁盘格式，逐一钉死防意外重命名迁移用户配置
        #expect(FanMode.system.rawValue == "system")
        #expect(FanMode.constant.rawValue == "constant")
        #expect(FanMode.curve.rawValue == "curve")
        #expect(FanMode(rawValue: "curve") == .curve)
        #expect(FanMode(rawValue: "auto") == nil)
    }
}
