import Foundation

// MARK: - 曲线模型（T-026 · A5 TF-21）

/// 曲线控制点：温度 → 目标转速。
public struct FanCurvePoint: Codable, Sendable, Equatable {
    public let celsius: Double
    public let rpm: Int

    public init(celsius: Double, rpm: Int) {
        self.celsius = celsius
        self.rpm = rpm
    }
}

/// 温度→转速折线（每风扇一条，A5·TF-21）。
/// 构造即按温度升序归一化：插值只认有序折线，曲线编辑器拖点与手改 JSON
/// 都不必预排序；不足 2 点由调用方（decide）当无效曲线拒用，本类型不做强校验，
/// 保持"数据容器 + 纯求值"的薄身位。
public struct FanCurve: Codable, Sendable, Equatable {
    public let points: [FanCurvePoint]

    public init(points: [FanCurvePoint]) {
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: any Decoder) throws {
        // 解码同走归一化入口：磁盘旧数据/手改 JSON 的乱序点也收敛成有效折线
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([FanCurvePoint].self, forKey: .points))
    }

    /// 折线求值：段内线性插值；区间外取端点转速——不外推，
    /// 外推值可能越过厂商上限（钳制前先不制造越界数）。
    /// 少于 2 点构不成折线：单点恒定该转速、空曲线返回 0（由 rpmClamped
    /// 钳到厂商下限），绝不凭空猜转速。
    public func rpm(forCelsius celsius: Double) -> Int {
        guard points.count > 1 else { return points.first?.rpm ?? 0 }
        let first = points[0]
        let last = points[points.count - 1]
        if celsius <= first.celsius { return first.rpm }
        if celsius >= last.celsius { return last.rpm }
        for i in 1..<points.count where celsius <= points[i].celsius {
            let a = points[i - 1]
            let b = points[i]
            let span = b.celsius - a.celsius
            // 重复横坐标的零宽段跳过（排序后仅脏数据会出现），落进下一段取后者
            guard span > 0 else { continue }
            let t = (celsius - a.celsius) / span
            return Int((Double(a.rpm) + t * Double(b.rpm - a.rpm)).rounded())
        }
        return last.rpm
    }

    /// 钳制进厂商 min–max 的目标转速（A5·第 4 节边界钳制）：一切写入值的唯一出口形态。
    public func rpmClamped(forCelsius celsius: Double, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(rpm(forCelsius: celsius), min), max)
    }
}

// MARK: - 内置预设（A5·TF-21）
// 数值按 Apple Silicon 笔记本名义区间 1200–5500 RPM 设计（本仓真机探测另见
// 1000–4900 一档），落到具体风扇时由 rpmClamped 钳进厂商 min–max，故不必逐机型精确。
// 所有预设顶点都顶到 5500：极热区绝不压制散热（A5·第 4 节"最坏情况也不伤机器"）；
// 105°C 封顶对齐同节"温度超过 105°C 应急全速"。
extension FanCurve {
    /// 安静：≤60°C 贴下限近无声（系统默认策略同区间也在下限附近运转），
    /// 75°C 起才快速爬坡，牺牲高温段噪音换取日常静音。
    public static let quiet = FanCurve(points: [
        .init(celsius: 35, rpm: 1200),
        .init(celsius: 60, rpm: 1300),
        .init(celsius: 75, rpm: 1800),
        .init(celsius: 90, rpm: 3200),
        .init(celsius: 105, rpm: 5500),
    ])

    /// 平衡：全程略高于系统默认曲线，80°C 已到 3400 阻止冲上 90+，拐点平滑防突兀变声。
    public static let balanced = FanCurve(points: [
        .init(celsius: 35, rpm: 1300),
        .init(celsius: 50, rpm: 1500),
        .init(celsius: 65, rpm: 2200),
        .init(celsius: 80, rpm: 3400),
        .init(celsius: 95, rpm: 4600),
        .init(celsius: 105, rpm: 5500),
    ])

    /// 性能：提前压温，65°C 即 3200，用常时噪音换取高温段更低的温度平台。
    public static let performance = FanCurve(points: [
        .init(celsius: 35, rpm: 1500),
        .init(celsius: 50, rpm: 2200),
        .init(celsius: 65, rpm: 3200),
        .init(celsius: 80, rpm: 4400),
        .init(celsius: 95, rpm: 5100),
        .init(celsius: 105, rpm: 5500),
    ])

    /// 全速：恒定名义上限（应急/除尘场景），写入时由钳制落到实际 F{x}Mx。
    public static let fullSpeed = FanCurve(points: [
        .init(celsius: 30, rpm: 5500),
        .init(celsius: 110, rpm: 5500),
    ])
}

// MARK: - 滞回（A5·TF-21 滞回带）
/// 滞回记忆：上次实际施加的转速。Codable 以便随配置持久化（T-026b 会话恢复用）。
public struct HysteresisState: Codable, Sendable, Equatable {
    public var lastAppliedRPM: Int?

    public init(lastAppliedRPM: Int? = nil) {
        self.lastAppliedRPM = lastAppliedRPM
    }
}

extension FanCurve {
    /// 带滞回的曲线求值（A5·TF-21"升降温各用一条曲线，默认相差 3°C"）。
    /// 升温（主曲线目标高于上次施加值）走主曲线；
    /// 降温走阈值整体下移 band 的低曲线——等价于按 celsius+band 求值主曲线
    /// 再封顶上次施加值：转速下台阶比上台阶晚 band 度，阈值附近的温度抖动被吸收，
    /// 且降温路径绝不把转速推高（封顶 lastAppliedRPM 挡住向上爬齿）。
    public static func rpm(
        forCelsius celsius: Double,
        curve: FanCurve,
        min: Int,
        max: Int,
        hysteresis: HysteresisState,
        band: Double = 3
    ) -> Int {
        let main = curve.rpmClamped(forCelsius: celsius, min: min, max: max)
        guard let last = hysteresis.lastAppliedRPM, main <= last else { return main }
        // 负带宽是脏配置：按 0 处理，宁无滞回也不"提前下台阶"
        let band = Swift.max(0, band)
        let lagged = curve.rpmClamped(forCelsius: celsius + band, min: min, max: max)
        return Swift.min(last, lagged)
    }
}
