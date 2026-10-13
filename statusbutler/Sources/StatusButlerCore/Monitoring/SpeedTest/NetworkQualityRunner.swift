import Foundation

// T-217（E17）：网络测速——/usr/bin/networkQuality 封装。
// 真机实测（macOS 26 arm64，2026-10，探针钉死）：
// 1. `networkQuality -v -c` 在本机 stdout 只输出"一个"美化排版的完整 JSON 对象
//    （约 1200 行，含 responsiveness 数组），无流式 progress 行、stderr 为空——
//    进度按任务书允许的降级口径走"开始/结束两态"，绝不伪造中间值。
// 2. 速率字段 dl_throughput/ul_throughput 单位是 字节/秒（非 bit）；base_rtt 单位毫秒；
//    il_h2_req_resp 是加载下 HTTP 往返延迟样本（毫秒）——抖动的数据源（-v 才输出）。
// 3. 解析器仍按"多对象流 + 坏对象跳过"写：summary 判据 = 最后一个含吞吐字段的对象，
//    未来系统改回流式 progress 行也吃得下。
// 权限边界：networkQuality 是系统自带只读诊断工具，路径与参数皆编译期常量
// （AU-04 同源纪律），不构成任意命令执行面。

// MARK: - 结果模型

/// 一次测速结果：吞吐单位十进制 Mbps（B/s × 8 ÷ 1e6，与 speedtest 生态口径一致）。
/// 各维度 nil = 本次未测得（缺字段/坏值），绝不以 0 冒充未测。
public struct SpeedTestResult: Sendable, Equatable {
    public let downloadMbps: Double?
    public let uploadMbps: Double?
    /// 基础 RTT（毫秒）；输出未含 base_rtt 时 nil
    public let latencyMs: Double?
    /// 相邻延迟样本平均绝对差（毫秒）；样本不足或数组缺失时 nil
    public let jitterMs: Double?
    public let timestamp: Date

    public init(
        downloadMbps: Double?,
        uploadMbps: Double?,
        latencyMs: Double?,
        jitterMs: Double?,
        timestamp: Date = Date()
    ) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.timestamp = timestamp
    }
}

// MARK: - 监控器协议（AGENTS：监控器全部协议化，测试注入假实现）

public protocol SpeedTesting: Sendable {
    /// 进度 0.0（开始）→ 1.0（结束）。本机输出无中间进度（见文件头注记），当前为两态。
    func run(onProgress: (@Sendable (Double) -> Void)?) async -> SpeedTestResult?
}

extension SpeedTesting {
    /// 不关心进度的便捷入口（任务书原始形态）
    public func run() async -> SpeedTestResult? { await run(onProgress: nil) }
}

// MARK: - 监控器

/// networkQuality 封装：拉起固定命令收 stdout，解析交给纯函数。
public struct NetworkQualityRunner: SpeedTesting {
    /// 只读白名单路径（A2·S12：不越权执行面）
    public static let executablePath = "/usr/bin/networkQuality"
    /// -c 出机器可读 JSON；-v 附 responsiveness 数组（抖动数据源）
    public static let arguments = ["-v", "-c"]

    /// stdout 收集器：live 跑真命令；测试注入假闭包零系统依赖验证全链路（HealthChecking 同源）
    public typealias OutputCollector = @Sendable () async -> String?

    private let collect: OutputCollector

    public init(collect: OutputCollector? = nil) {
        self.collect = collect ?? { await Self.launch() }
    }

    public func run(onProgress: (@Sendable (Double) -> Void)?) async -> SpeedTestResult? {
        onProgress?(0)
        let stdout = await collect()
        let result = Self.parse(stdout: stdout ?? "")
        onProgress?(1)
        return result
    }

    // MARK: - 进程拉起

    /// 跑 networkQuality 收 stdout（整机约 15~30 秒）。读与等置于全局队列：
    /// 一是不占 Swift 并发协作线程（阻塞式 waitUntilExit），二是 Process 全生命周期
    /// 收敛在同一闭包内——无非 Sendable 跨隔离捕获（Swift 6 严格并发边界）。
    /// 拉起失败/非零退出/编码失败 → nil（降级不抛错）。先读后等防管道缓冲互锁
    /// （HealthChecks 存档同源坑：读 EndeOfFile 必须发生在 waitUntilExit 之前）。
    static func launch(
        path: String = executablePath,
        arguments: [String] = arguments
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()  // stderr 弃置：判定只依据 stdout
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    // MARK: - 解析（纯函数，单测入口）

    /// stdout → 结果：取"最后一个含吞吐字段"的 JSON 对象作 summary（progress-only
    /// 对象天然出局）；无可用对象或吞吐数字一个都没有 → nil。
    /// 坏对象逐个跳过，绝不因夹杂噪声行整体失败。
    public static func parse(stdout: String) -> SpeedTestResult? {
        guard let summary = jsonObjects(in: stdout).last(where: { object in
            object["dl_throughput"].flatMap(throughput) != nil
                || object["ul_throughput"].flatMap(throughput) != nil
        }) else { return nil }
        return SpeedTestResult(
            downloadMbps: summary["dl_throughput"].flatMap(throughput),
            uploadMbps: summary["ul_throughput"].flatMap(throughput),
            latencyMs: summary["base_rtt"].flatMap(Self.number),
            jitterMs: jitterMs(samples: latencySamples(summary)),
            timestamp: Date()
        )
    }

    /// 容错抽取 stdout 里的全部顶层 JSON 对象：先整段解析（macOS 26 实测形态：
    /// 单个美化大对象）；失败再走括号配对扫描（流式行/坏行夹杂形态，扫描感知
    /// 字符串与转义，配对片段解析失败的丢弃）。两条腿都空手 → []。
    static func jsonObjects(in text: String) -> [[String: Any]] {
        if let data = text.data(using: .utf8),
           let whole = try? JSONSerialization.jsonObject(with: data) {
            return flattenedObjects(whole)
        }
        var objects: [[String: Any]] = []
        var depth = 0
        var start = text.startIndex
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0,
                   let data = text[start...index].data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    objects.append(object)
                }
            default:
                break
            }
        }
        return objects
    }

    private static func flattenedObjects(_ json: Any) -> [[String: Any]] {
        if let object = json as? [String: Any] { return [object] }
        if let array = json as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return []
    }

    // MARK: - 数值消毒与换算

    /// B/s → Mbps（十进制）。networkQuality 吞吐单位是字节每秒（真机实测钉死）。
    /// 负值/NaN/Infinity/非数值判无效——宁缺毋假。
    static func throughput(_ value: Any) -> Double? {
        number(value).map { $0 * 8 / 1e6 }
    }

    /// 通用数值消毒：拒布尔（JSONSerialization 的 true/false 也是 NSNumber，需按
    /// CF 类型剥离）、拒非有限、拒负数。
    static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite && double >= 0 ? double : nil
    }

    /// 抖动数据源：优先加载下往返（il_h2_req_resp），缺失退轻载下行样本
    /// （lud_foreign_h2_req_resp）；两数组都没有 → 空。
    static func latencySamples(_ object: [String: Any]) -> [Double] {
        for key in ["il_h2_req_resp", "lud_foreign_h2_req_resp"] {
            if let array = object[key] as? [Any] {
                let samples = array.compactMap(number)
                if !samples.isEmpty { return samples }
            }
        }
        return []
    }

    /// 抖动 = 相邻样本平均绝对差（毫秒）。样本 <2 无法差分 → nil。
    public static func jitterMs(samples: [Double]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let differences = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        return differences.reduce(0, +) / Double(differences.count)
    }
}
