import Foundation

// MARK: - 控制模式与配置（T-026 · A5 TF-20/TF-22）
/// 三种控制模式（A5·TF-20）。rawValue 是持久化格式，改字符串等于迁移用户配置，冻结。
public enum FanMode: String, Codable, Sendable, Equatable {
    case system  // 系统自动（默认）：不写入仅监测，零风险起步
    case constant  // 手动恒速
    case curve  // 自定义曲线
}

public struct FanControlConfig: Codable, Sendable, Equatable {
    public var mode: FanMode
    public var constantRPM: Int?
    public var curve: FanCurve?
    /// 只升不降（smcFanControl 哲学）：目标低于系统当前策略时交还系统而非压低转速，
    /// 防止用固定值压制散热。默认开；用户可关但 UI 侧需二次确认（A5·TF-20），
    /// 本层只忠实执行开关。
    public var onlyRaiseAboveSystem: Bool
    /// 滞回带宽（°C），A5·TF-21 默认 3。
    public var hysteresisBand: Double

    public init(
        mode: FanMode = .system,
        constantRPM: Int? = nil,
        curve: FanCurve? = nil,
        onlyRaiseAboveSystem: Bool = true,
        hysteresisBand: Double = 3
    ) {
        self.mode = mode
        self.constantRPM = constantRPM
        self.curve = curve
        self.onlyRaiseAboveSystem = onlyRaiseAboveSystem
        self.hysteresisBand = hysteresisBand
    }
}

/// 引擎输出：本轮该做什么。leaveSystem 意味着零写入；
/// setRPM 的值已经过钳制，特权 Helper（T-026b）无需再加工。
public enum FanDecision: Equatable, Sendable {
    case leaveSystem
    case setRPM(Int)
}

// MARK: - 纯逻辑引擎（A5·TF-22"曲线引擎为纯函数"）
/// 决定器：温度 + 风扇读数 + 配置 + 滞回状态 → 决策。本层零系统调用、零 SMC 写入；
/// 写路径与节流时钟的落盘全在调用方（Helper/XPC 任务）。
public enum FanControlEngine {
    public static func decide(
        config: FanControlConfig,
        celsius: Double?,
        fan: FanReading,
        state: inout HysteresisState
    ) -> FanDecision {
        switch config.mode {
        case .system:
            // 交还系统后"上次施加值"不再代表真实转速，滞回记忆作废
            state = HysteresisState()
            return .leaveSystem

        case .constant:
            // 恒速缺目标值不猜（护栏：宁可不控也不写凭空转速）
            guard let raw = config.constantRPM else { return .leaveSystem }
            let target = Swift.min(Swift.max(raw, fan.minRPM), fan.maxRPM)
            if config.onlyRaiseAboveSystem, target < fan.currentRPM {
                return .leaveSystem
            }
            state.lastAppliedRPM = target
            return .setRPM(target)

        case .curve:
            // 温度源缺失/故障哨兵（A5·TF-01 合理性闸）、曲线缺失或不足 2 点：
            // 绝不带旧值或脏数据写转速
            guard let celsius,
                  ThermalMonitor.isPlausibleCelsius(celsius),
                  let curve = config.curve,
                  curve.points.count >= 2
            else { return .leaveSystem }
            let target = FanCurve.rpm(
                forCelsius: celsius,
                curve: curve,
                min: fan.minRPM,
                max: fan.maxRPM,
                hysteresis: state,
                band: config.hysteresisBand
            )
            if config.onlyRaiseAboveSystem, target < fan.currentRPM {
                // 曲线目标低于系统当前转速：让系统继续。此处不重置滞回记忆——
                // 目标随时可能重新越过系统转速，跨回合的方向记忆仍然有效
                return .leaveSystem
            }
            state.lastAppliedRPM = target
            return .setRPM(target)
        }
    }

    /// 写节流（A5·TF-22：间隔 ≥ 2s **或** 目标变化 > 200 RPM 才写）。
    /// 交还系统是安全关键转换（恢复散热默认策略），永不节流。
    public static func shouldWrite(
        previous: FanDecision?,
        next: FanDecision,
        lastWriteAt: Date?,
        now: Date,
        minInterval: TimeInterval = 2,
        minDeltaRPM: Int = 200
    ) -> Bool {
        guard let previous else { return true }  // 首写立即放行
        guard previous != next else { return false }  // 决策未变：重复写同值毫无意义
        if case .leaveSystem = next { return true }
        // 交还系统后的首次设定：系统侧转速未知、差值不可算，视为全量变化
        let delta: Int
        if case .setRPM(let a) = previous, case .setRPM(let b) = next {
            delta = abs(a - b)
        } else {
            delta = .max
        }
        let intervalOK = lastWriteAt.map { now.timeIntervalSince($0) >= minInterval } ?? true
        return intervalOK || delta > minDeltaRPM
    }
}

// MARK: - 接管自愈（A5·TF-22 退出/崩溃恢复）
/// 接管状态机：本结构只是内存判定载体；持久化落盘由 T-026b 的 Helper/设置层负责。
/// 语义：接管前先写标记、正常退出（注销/关机/用户关闭）清标记并写回系统模式；
/// 标记残留 = 上次没走正常退出。
public struct TakeoverTracker: Sendable, Equatable {
    public var isTakenOver: Bool
    public var takeoverAt: Date?

    public init(isTakenOver: Bool = false, takeoverAt: Date? = nil) {
        self.isTakenOver = isTakenOver
        self.takeoverAt = takeoverAt
    }

    /// 拿到风扇控制权（写 FS!=02 前）。时钟由调用方注入，默认值仅供便捷调用。
    public mutating func markTakenOver(at date: Date = Date()) {
        isTakenOver = true
        takeoverAt = date
    }

    /// 交还系统控制（写 FS!=01 后）：清标记，下次启动即无需自愈。
    public mutating func relinquish() {
        isTakenOver = false
        takeoverAt = nil
    }

    /// 启动自愈判定（A5·TF-22"绝不带着用户的风扇设置悄悄跑"）：
    /// 本次会话尚未接管、但持久化残留"接管中"标记 ⇒ 上次会话异常退出，
    /// 必须先写回系统自动模式再询问是否恢复接管。返回 false = 无需自愈。
    public func shouldRestoreOnLaunch(persistedTakeover: TakeoverTracker?) -> Bool {
        // 本会话已接管：属唤醒重应用/正常运行，不是异常退出自愈
        guard !isTakenOver else { return false }
        return persistedTakeover?.isTakenOver == true
    }
}
