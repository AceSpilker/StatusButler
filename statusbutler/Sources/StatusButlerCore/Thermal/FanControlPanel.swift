import AppKit
import Combine
import Foundation

// MARK: - 温控控制面板 VM（T-222c · A5 TF-20/22 接管状态机）
// 弹层"温度与风扇"分区的控制数据面：三模式切换的接管生命周期 +
// 引擎循环（读温度 → FanControlEngine.decide → shouldWrite 节流 → helper 写）。
// 引擎本身是已测纯函数（T-026 FanControlTests），本层只做编排与安全转换：
//   接管：markTakenOver → FS!=02 → 循环写目标转速
//   退出/睡眠/写通道坏：FS!=01（restoreSystem）+ relinquish——先还权再停手
//   唤醒：按睡眠前意图重应用（A5·TF-22"睡眠时放弃接管，唤醒后重应用"）
// UI 消费面：mode 徽标 / 当前 RPM / 曲线预览点与实时工作点 / 接管徽标。
// 设置持久化（config 落盘）经 persist 闭包外置——SettingsStore 尚无风扇键位，
// 接线是设置页任务的半场（见文末集成注记），本层不私自开 UserDefaults 新键。

/// 接管状态（面板徽标数据源）。isTakenOver 只回答"现在是我们说了算吗"；
/// 模式语义（系统/恒速/曲线）看 config.mode。
public enum FanTakeoverStatus: Equatable, Sendable {
    case released
    case takenOver
}

@MainActor
public final class FanControlPanel: ObservableObject {
    // MARK: - 面板消费的数据面

    @Published public private(set) var config: FanControlConfig
    @Published public private(set) var isTakenOver = false
    @Published public private(set) var isHelperInstalled: Bool
    /// 主风扇当前转速（快照刷新，面板转速条数据源）
    @Published public private(set) var currentRPM: Int?
    /// 本轮最高温（曲线工作点的横轴；nil = 读数缺席，工作点随之消失）
    @Published public private(set) var currentCelsius: Double?
    /// 写通道连续失败计数上浮的错误文案（"需安装 Helper"等诚实降级信息）
    @Published public private(set) var statusMessage: String?

    // MARK: - 注入

    private let writer: any FanWriting
    private let snapshotProvider: @MainActor () async -> ThermalSnapshot?
    private let clock: () -> Date
    /// 循环节拍。生产 1s（读侧廉价、写侧另受 shouldWrite ≥2s 节流）；测试注入 0.05s
    private let tickInterval: TimeInterval
    /// 配置变更上浮（设置层落盘）。默认 no-op：设置键位接线前不丢数据也不私自开键
    private let persist: (FanControlConfig) -> Void
    /// helper 可用性探测（安装引导的判据）。默认探二进制在位——
    /// 更强探测（ping 往返）由组合根注入
    private let probeAvailability: () async -> Bool

    // MARK: - 状态机内部

    private var tracker = TakeoverTracker()
    private var controlTask: Task<Void, Never>?
    /// 每风扇一份：同一曲线作用在所有风扇上，但滞回/节流记忆按风扇独立
    private var hysteresisByFan: [Int: HysteresisState] = [:]
    private var lastDecisionByFan: [Int: FanDecision] = [:]
    private var lastWriteAtByFan: [Int: Date] = [:]
    /// 写通道连续失败数（成功一次即清零——与 AXMenubarApplier 的"连续"口径同哲学）
    private var consecutiveWriteFailures = 0
    private static let writeFailureLimit = 3
    /// 睡眠时的接管意图（唤醒后重应用的依据）
    private var wakeIntent: FanMode?
    private var wakeSubscribers: [Any] = []

    public init(
        config: FanControlConfig = FanControlConfig(),
        writer: any FanWriting,
        snapshotProvider: @escaping @MainActor () async -> ThermalSnapshot? = {
            await ThermalMonitor().read()
        },
        clock: @escaping () -> Date = Date.init,
        tickInterval: TimeInterval = 1,
        persist: @escaping (FanControlConfig) -> Void = { _ in },
        probeAvailability: (@Sendable () async -> Bool)? = nil
    ) {
        self.config = config
        self.writer = writer
        self.snapshotProvider = snapshotProvider
        self.clock = clock
        self.tickInterval = tickInterval
        self.persist = persist
        // 默认可用性 = writer 是 FanHelperClient 时探其安装位；假件注入时恒 true，
        // 让状态机测试聚焦接管时序而不是安装态
        if let probeAvailability {
            self.probeAvailability = probeAvailability
        } else if let client = writer as? FanHelperClient {
            self.probeAvailability = { client.isInstalled }
        } else {
            self.probeAvailability = { true }
        }
        self.isHelperInstalled = false  // start() 首探后置真——构造期不碰 IO
    }

    // MARK: - 生命周期

    /// 面板激活时调用：探测 helper + 订阅睡眠/唤醒/退出。幂等。
    public func start() async {
        await refreshAvailability()
        guard wakeSubscribers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        wakeSubscribers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleSystemSleep() } })
        wakeSubscribers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleSystemWake() } })
        // 应用退出必须还权（TF-22"绝不带着用户的风扇设置悄悄跑"）：
        // 注销/关机路径系统会杀进程，靠的是守护进程侧自愈；这里兜正常退出
        wakeSubscribers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleSystemSleep() } })
    }

    public func refreshAvailability() async {
        isHelperInstalled = await probeAvailability()
        if !isHelperInstalled {
            statusMessage = "需安装 Helper（设置页引导安装，需管理员确认）"
        } else if statusMessage == "需安装 Helper（设置页引导安装，需管理员确认）" {
            statusMessage = nil
        }
    }

    // MARK: - 模式与配置（面板三模式切换入口）

    public var mode: FanMode { config.mode }
    public var curve: FanCurve? { config.curve }

    /// 曲线预览点（编辑器折线数据源；非曲线模式返回 nil 由 UI 灰显）
    public var curvePreviewPoints: [FanCurvePoint]? { config.curve?.points }

    /// 实时工作点（当前温度 ↔ 曲线目标转速，A5·TF-21"实时预览当前工作点"）。
    /// 无读数/无曲线/无风扇时 nil——工作点消失而不是停在旧值。
    public var workingPoint: FanCurvePoint? {
        guard let celsius = currentCelsius,
              let curve = config.curve,
              let fan = latestPrimaryFan
        else { return nil }
        return FanCurvePoint(
            celsius: celsius,
            rpm: curve.rpmClamped(forCelsius: celsius, min: fan.minRPM, max: fan.maxRPM)
        )
    }

    /// 配置整体替换（设置页/编辑器保存路径）。接管中切回 .system 立即还权——
    /// 不等下一轮循环，"系统自动"必须即时生效（用户点了就还）。
    public func apply(_ newConfig: FanControlConfig) async {
        config = newConfig
        persist(newConfig)
        await reconcileTakeoverWithMode()
    }

    public func setMode(_ mode: FanMode) async {
        var new = config
        new.mode = mode
        await apply(new)
    }

    public func setCurve(_ curve: FanCurve?) async {
        var new = config
        new.curve = curve
        if new.mode != .curve { new.mode = .curve }  // 画曲线即选曲线模式（面板语义）
        await apply(new)
    }

    public func setConstantRPM(_ rpm: Int) async {
        var new = config
        new.constantRPM = rpm
        if new.mode != .constant { new.mode = .constant }
        await apply(new)
    }

    /// 模式 ↔ 接管态对账：非系统模式且 helper 可用 → 接管；系统模式 → 还权。
    private func reconcileTakeoverWithMode() async {
        if config.mode == .system {
            if isTakenOver { await endTakeover() }
        } else if !isTakenOver, isHelperInstalled {
            await beginTakeover()
        } else if !isTakenOver, !isHelperInstalled {
            statusMessage = "需安装 Helper（设置页引导安装，需管理员确认）"
        }
    }

    // MARK: - 接管状态机

    /// 接管：markTakenOver（先写标记，TF-22 崩溃自愈的前提）→ FS!=02 → 循环。
    public func beginTakeover() async {
        guard !isTakenOver else { return }
        // start() 之前（或安装态从未探测过）的裸调用也允许接管：先探再判
        if !isHelperInstalled { await refreshAvailability() }
        guard isHelperInstalled else {
            statusMessage = "需安装 Helper（设置页引导安装，需管理员确认）"
            return
        }
        tracker.markTakenOver(at: clock())
        isTakenOver = true
        consecutiveWriteFailures = 0
        // 强制手动模式先行：FS!=02 之前写目标转速是无效写（系统策略仍在管）
        guard await writer.setMode(FanHelperKeys.forcedManualMode) else {
            await abortTakeoverDueToWriteFailure()
            return
        }
        controlTask = Task { [weak self] in
            await self?.runControlLoop()
        }
    }

    /// 还权：停循环 → FS!=01 → relinquish。写失败也要走完（尽力还权），
    /// 返回值供调用方知晓是否需要向用户提示"可能仍在手动模式"。
    @discardableResult
    public func endTakeover() async -> Bool {
        controlTask?.cancel()
        controlTask = nil
        let restored = await writer.restoreSystem()
        tracker.relinquish()
        isTakenOver = false
        hysteresisByFan = [:]
        lastDecisionByFan = [:]
        lastWriteAtByFan = [:]
        latestPrimaryFan = nil
        if !restored {
            statusMessage = "已退出接管，但还权写失败——请留意风扇是否恢复系统自动"
        } else if statusMessage != nil {
            statusMessage = nil
        }
        return restored
    }

    private func runControlLoop() async {
        while !Task.isCancelled {
            guard let snapshot = await snapshotProvider() else {
                // 读路径整体不可用（虚拟机/IOKit 异常）：不写不猜，静待下一拍
                try? await Task.sleep(for: .seconds(tickInterval))
                continue
            }
            currentCelsius = snapshot.maxCelsius
            guard !snapshot.fans.isEmpty else {
                try? await Task.sleep(for: .seconds(tickInterval))
                continue
            }
            if let primary = snapshot.fans.first {
                currentRPM = primary.currentRPM
                latestPrimaryFan = primary
            }
            let now = clock()
            for fan in snapshot.fans {
                await tick(fan: fan, celsius: snapshot.maxCelsius, now: now)
            }
            try? await Task.sleep(for: .seconds(tickInterval))
        }
    }

    /// 单风扇一轮：decide（纯函数，已测）→ shouldWrite 节流 → helper 写
    private func tick(fan: FanReading, celsius: Double?, now: Date) async {
        var hysteresis = hysteresisByFan[fan.id] ?? HysteresisState()
        let decision = FanControlEngine.decide(
            config: config, celsius: celsius, fan: fan, state: &hysteresis
        )
        hysteresisByFan[fan.id] = hysteresis

        guard FanControlEngine.shouldWrite(
            previous: lastDecisionByFan[fan.id],
            next: decision,
            lastWriteAt: lastWriteAtByFan[fan.id],
            now: now
        ) else { return }

        switch decision {
        case .leaveSystem:
            lastDecisionByFan[fan.id] = decision
            // leaveSystem = 目标低于系统当前策略（只升不降）：保持接管但不写，
            // 系统侧转速自行维持。lastWriteAt 不更新——这不是一次写
        case .setRPM(let rpm):
            guard await writer.setRPM(rpm, fan: fan.id) else {
                await noteWriteFailure()
                return
            }
            consecutiveWriteFailures = 0
            lastDecisionByFan[fan.id] = decision
            lastWriteAtByFan[fan.id] = now
        }
    }

    private func noteWriteFailure() async {
        consecutiveWriteFailures += 1
        guard consecutiveWriteFailures >= Self.writeFailureLimit else { return }
        await abortTakeoverDueToWriteFailure()
    }

    /// 写通道坏掉（helper 死/权限被撤/机型不支持）：先还权再退出接管，
    /// 并刷新安装态——"需安装 Helper"的诚实降级从这来（A5 风险表"写失败自动
    /// 回退系统自动并提示"）
    private func abortTakeoverDueToWriteFailure() async {
        _ = await endTakeover()
        await refreshAvailability()
        if isHelperInstalled {
            statusMessage = "写通道连续失败，已交还系统自动——请查看风扇是否正常"
        }
    }

    // MARK: - 睡眠/唤醒（TF-22：睡眠放弃接管，唤醒重应用）

    /// 睡眠前还权（直接调用于 NSWorkspace 回调与测试）
    public func handleSystemSleep() {
        wakeIntent = isTakenOver ? config.mode : nil
        guard isTakenOver else { return }
        Task { await endTakeover() }
    }

    /// 唤醒后按意图重应用
    public func handleSystemWake() {
        guard let intent = wakeIntent, intent != .system else {
            wakeIntent = nil
            return
        }
        wakeIntent = nil
        guard isHelperInstalled else { return }
        Task { await beginTakeover() }
    }

    /// 工作点计算用的最近主风扇（跨 tick 缓存，避免读数缺席时工作点抖动消失）
    private var latestPrimaryFan: FanReading?

    // MARK: - 集成注记（AppEnvironment/LiveServices 接线说明——App/ 不归本任务改动）
    //
    // LiveServices.start(popover:) 内三行即可点亮（与 MobileBattery/iDevice 同姿势）：
    //   let fanPanel = FanControlPanel(writer: FanHelperClient())
    //   await fanPanel.start()
    //   // 弹层"温度与风扇"分区持有 fanPanel；config 持久化接入 SettingsStore 时
    //   // 注入 persist 闭包（键位 FanControlConfig Codable 直存），
    //   // 三模式切换走 setMode/setCurve/setConstantRPM，接管徽标绑 isTakenOver，
    //   // 转速条绑 currentRPM，安装引导文案绑 statusMessage（"需安装 Helper"）。
    // 安装动作（SMAppService.register）不在本半场——用户管理员确认后由设置页触发。
}
