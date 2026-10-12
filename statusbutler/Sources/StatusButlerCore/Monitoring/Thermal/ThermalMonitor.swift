import Foundation

// MARK: - 读数模型（T-025）

public struct FanReading: Sendable, Equatable {
    public let id: Int  // 风扇序号（SMC F{id}Ac 键位中的 id）
    public let minRPM: Int
    public let maxRPM: Int
    public let currentRPM: Int

    public init(id: Int, minRPM: Int, maxRPM: Int, currentRPM: Int) {
        self.id = id
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.currentRPM = currentRPM
    }
}

public struct SensorReading: Sendable, Equatable {
    public let key: String  // SMC 键（如 "TC0P"），机型目录靠它对齐
    public let name: String?  // 展示名；nil = 未知（探测收录但目录未覆盖，UI 兜底显示 key）
    public let celsius: Double

    public init(key: String, name: String?, celsius: Double) {
        self.key = key
        self.name = name
        self.celsius = celsius
    }
}

public struct ThermalSnapshot: Sendable, Equatable {
    public let fans: [FanReading]
    public let sensors: [SensorReading]

    /// 全部有效传感器中的最高温（E1 槽位"最高温"源）。计算属性而非存储：
    /// 与 sensors 永远一致，快照相等性天然成立。无有效传感器时 nil。
    public var maxCelsius: Double? { sensors.map(\.celsius).max() }

    public init(fans: [FanReading], sensors: [SensorReading]) {
        self.fans = fans
        self.sensors = sensors
    }
}

// MARK: - 监控器

/// 温度/风扇一次性读取器（A5·TF-01/TF-10 读路径）。
/// 采样纪律：只在 read() 被调用时读一次，无常驻循环、无定时器——"有人看才采样"。
public struct ThermalMonitor: Sendable {
    public init() {}

    /// 内置通用候选温度键（A5·TF-01"机型目录 + 探测兜底"策略的探测半边：
    /// 传感器键位随机型差异极大且无官方文档，本版先内置通用候选表逐个探测、
    /// 读得到且解码成功才收录；按 hw.model 的机型目录属后续任务，接入后替换此表）。
    static let temperatureKeyCandidates: [(key: String, name: String)] = [
        ("TC0P", "CPU 附近"),
        ("TC0D", "CPU 核心"),
        ("TG0P", "GPU 附近"),
        ("TG0D", "GPU 核心"),
        ("TB1T", "电池 1"),
        ("TB2T", "电池 2"),
        ("TM0P", "主板"),
        ("Ts0S", "掌托"),
        ("TA0P", "环境"),
    ]

    /// 风扇数上限钳制：FNum 读出异常大值时防呆，不无限枚举键位
    static let maxFanCount = 8

    /// 读一次温度+风扇。
    /// 返回 nil 仅发生在 AppleSMC 连接失败（虚拟机/IOKit 异常）——整体不可用而非部分缺失；
    /// 单个键读取/解码失败按 A5"静默降级"跳过。
    public func read() async -> ThermalSnapshot? {
        // 阻塞 IOKit 调用收敛在 nonisolated static；read() 只做编排
        Self.readSync()
    }

    nonisolated static func readSync() -> ThermalSnapshot? {
        let client = SMCClient()
        guard client.open() else { return nil }
        defer { client.close() }

        var fans: [FanReading] = []
        if let fnum = client.readValue(key: "FNum"),
           let count = fanCount(type: fnum.type, bytes: fnum.bytes) {
            for i in 0..<min(count, maxFanCount) {
                // F{n}Ac/Mn/Mx 的值类型随机型浮动（arm64 真机实测为 flt，旧机型为 fpe2），
                // 一律按 SMC 报告的类型分发解码；缺任一键跳过该风扇，不猜
                guard let ac = client.readValue(key: "F\(i)Ac"),
                      let mn = client.readValue(key: "F\(i)Mn"),
                      let mx = client.readValue(key: "F\(i)Mx"),
                      let current = fanRPM(type: ac.type, bytes: ac.bytes),
                      let minRPM = fanRPM(type: mn.type, bytes: mn.bytes),
                      let maxRPM = fanRPM(type: mx.type, bytes: mx.bytes)
                else { continue }
                fans.append(FanReading(id: i, minRPM: minRPM, maxRPM: maxRPM, currentRPM: current))
            }
        }

        var sensors: [SensorReading] = []
        for candidate in temperatureKeyCandidates {
            guard let value = client.readValue(key: candidate.key),
                  let celsius = decodeTemperature(type: value.type, bytes: value.bytes),
                  isPlausibleCelsius(celsius)
            else { continue }
            sensors.append(SensorReading(key: candidate.key, name: candidate.name, celsius: celsius))
        }
        return ThermalSnapshot(fans: fans, sensors: sensors)
    }

    // MARK: - 纯解码函数（单测入口，不碰 IOKit）

    /// fpe2 → UInt16 大端**原始值**（任务口径：[0x0A,0x00]→2560）。
    /// 注意物理换算：fpe2 把数值 ×4 编码（stats 的 Int(fromFPE2:) = raw>>2 同源），
    /// 真实 RPM = 原始值 / 4，换算收口在 fanRPM(type:bytes:)。
    public static func decodeFPE2(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        return Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    /// flt（Float32）→ 摄氏度。字节序为**本机序**而非大端：
    /// arm64 真机探测证明（F0Mn=1000/F0Mx=4900 等出厂整值只有本机序解读成立，
    /// 大端解读为 1e-38 级垃圾值），与 stats 的 Float.load(as:) 同口径。
    /// NaN 视为传感器故障返回 nil。
    public static func decodeFLT(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let value = bytes.withUnsafeBytes { raw in
            raw.load(fromByteOffset: 0, as: Float32.self)
        }
        return value.isNaN ? nil : Double(value)
    }

    /// 大端 Float32 解读（社区旧文档流传的 flt 字节序），仅作 decodeTemperature 的兜底
    static func decodeFLTBigEndian(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        let value = Float32(bitPattern: bits)
        return value.isNaN ? nil : Double(value)
    }

    /// spui（UInt32 大端）→ 原始无符号整数
    public static func decodeSPUI(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    /// sp78（8.8 定点：高字节有符号整数 + 低字节/256）→ 摄氏度。
    /// 0x8100 → -127.0 正是常见故障哨兵，靠 isPlausibleCelsius 兜住。
    public static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256.0
    }

    /// 按值类型分发温度解码。fourcc "flt " 带尾随空格，trim 后比较；
    /// flt 优先本机序解读，落进物理不可能区间或近零（1e-38 量级的另一字节序误读形似 0）
    /// 时退回大端解读——两种字节序阵营都有实测机型，只保留物理合理的那一侧，
    /// 绝不显示假数据；未知类型不猜，返回 nil 由调用方跳过。
    static func decodeTemperature(type: String, bytes: [UInt8]) -> Double? {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard let native = decodeFLT(bytes) else { return nil }
            if looksLikeRealCelsius(native) { return native }
            if let bigEndian = decodeFLTBigEndian(bytes), looksLikeRealCelsius(bigEndian) {
                return bigEndian
            }
            return native  // 两侧都不合理：原样交给外层 isPlausibleCelsius 丢弃
        case "sp78": return decodeSP78(bytes)
        default: return nil
        }
    }

    /// 故障值防御（A5·TF-01）：-127 等哨兵与离谱读数按"不可用"丢弃。
    /// 窗口 -40…150：下限兼容严寒户外，上限留足异常高温观察空间，仅排除物理不可能值。
    static func isPlausibleCelsius(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > -40 && celsius < 150
    }

    /// 比 isPlausibleCelsius 更严的"像真实读数"判定，专用于 flt 字节序仲裁：
    /// 近零值（|v| < 0.1）几乎必是另一字节序解读出的 denormal 垃圾（1e-38 量级），
    /// 0.1 下限把它与真实读数区分开
    static func looksLikeRealCelsius(_ celsius: Double) -> Bool {
        isPlausibleCelsius(celsius) && abs(celsius) >= 0.1
    }

    /// 风扇字段（F{n}Ac/Mn/Mx）按 SMC 报告的类型解码为 RPM。
    /// flt（arm64 机型）：本机序 Float32；fpe2（经典机型）：UInt16 大端 ÷4。
    static func fanRPM(type: String, bytes: [UInt8]) -> Int? {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard let rpm = decodeFLT(bytes) else { return nil }
            return Int(rpm.rounded())
        case "fpe2":
            return decodeFPE2(bytes).map { $0 / 4 }
        default:
            return nil
        }
    }

    /// FNum 按类型解码：arm64 真机为 ui8 单字节；经典机型为 fpe2（值 ×4 编码）。
    static func fanCount(type: String, bytes: [UInt8]?) -> Int? {
        guard let bytes, !bytes.isEmpty else { return nil }
        switch type.trimmingCharacters(in: .whitespaces) {
        case "fpe2": return decodeFPE2(bytes).map { $0 / 4 }
        default: return Int(bytes[0])
        }
    }
}
