import Foundation

// MARK: - 风扇写路径客户端（T-222b · A5 TF-20 特权 Helper 代码半场）
// Support/FanHelper/main.swift 是独立特权子进程（stdin/stdout JSON 行协议，
// 键白名单 FS!/F{n}Md——红线二唯一例外），本文件是主程序侧的门面：
// Process 拉起 helper + 管道往返。真部署形态是 SMAppService LaunchDaemon
// 以 root 常驻（安装协议见 Support/FanHelper/main.swift 头注与
// com.statusbutler.fanhelper.plist 模板）；未安装时本客户端的写一律
// 返回 false——调用方（FanControlPanel/面板）据此诚实降级"需安装 Helper"，
// 绝不伪装成功。

/// 白名单键位（客户端侧第一道闸；helper 侧独立再校验——纵深防御：
/// 即使协议被绕过，特权进程仍是最后闸口）。
/// 这是红线二（A2·S12 修订版）在 Core 侧的可执行化：风扇域之外零写路径。
public enum FanHelperKeys {
    /// 强制模式键。协议写法 3 字符 "FS!"，SMC 键位实为 "FS! "（helper 侧补齐）。
    public static let modeKey = "FS!"
    /// 交还系统自动（写 FS! = 01）
    public static let systemAutoMode: UInt8 = 0x01
    /// 接管为强制手动（写 FS! = 02）
    public static let forcedManualMode: UInt8 = 0x02

    /// 风扇序号上限，对齐 ThermalMonitor.maxFanCount 的防呆口径。
    public static let maxFanIndex = 7

    /// 唯一放行域：FS! 与 F0Md…F7Md。其余一切键（温度读键/充电电源域键/未知键）
    /// 客户端直接拒绝，不产生子进程往返。
    public static func isWriteAllowed(key: String) -> Bool {
        if key == modeKey { return true }
        guard key.count == 4, key.hasPrefix("F"), key.hasSuffix("Md") else { return false }
        let digits = key.dropFirst().dropLast(2)  // 后缀 "Md" 占 2 字符
        guard digits.count == 1, let fan = digits.first, fan.isNumber else { return false }
        return (0...maxFanIndex).contains(Int(String(fan)) ?? -1)
    }

    /// 风扇序号 → 目标转速键。越界序号返回 nil（不猜）。
    public static func rpmKey(fan: Int) -> String? {
        guard (0...maxFanIndex).contains(fan) else { return nil }
        return "F\(fan)Md"
    }
}

/// 风扇写路径契约（FanControlPanel 消费；测试注入假实现）。
/// 全部写失败语义 = false：写路径失败是环境态（helper 未装/机型不支持/
/// 权限不足），不是程序错误，调用方降级而非崩溃。
public protocol FanWriting: Sendable {
    /// 原始写：键必须过 FanHelperKeys.isWriteAllowed，客户端侧先拒绝非白名单键
    func write(key: String, value: Int) async -> Bool
    /// 写 FS!（01 系统自动 / 02 强制手动）
    func setMode(_ mode: UInt8) async -> Bool
    /// 写 F{fan}Md 目标转速（RPM，调用方已钳制进厂商 min–max）
    func setRPM(_ rpm: Int, fan: Int) async -> Bool
    /// 交还系统控制（FS! = 01）。安全关键路径：失败也返回 false 由调用方决策重试
    func restoreSystem() async -> Bool
}

// MARK: - 管道行读取器

/// FileHandle → 按行取 String。availableData 循环自带 EOF 语义（空 chunk），
/// helper 进程死亡即闭管，阻塞中的读会自然返回 nil——看门狗"超时杀进程解锁读"
/// 依赖的正是这一点。
private final class PipeLineReader {
    private let handle: FileHandle
    private var buffer: [UInt8] = []

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// 读一行（含换行符剥离）。EOF/中断返回 nil。
    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineBytes = buffer[0..<newline]
                buffer.removeSubrange(0...newline)
                let line = String(decoding: lineBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // EOF：对端关闭
            buffer.append(contentsOf: chunk)
        }
    }

    /// 关闭底层读端（teardown 用；重复关闭由 try? 吸收）
    func close() {
        try? handle.close()
    }
}

// MARK: - 客户端实现

/// FanWriting 的真实现：Process 拉起 helper（路径注入），stdin/stdout JSON 行往返。
/// 线程模型：所有管道 IO 收敛在私有串行队列（一次一条请求，天然匹配面板的
/// 单写者节律）；async 包装经 continuation 跳出协作线程池，不阻塞 await 方。
/// helper 进程长驻复用（每次写都重拉进程会把接管循环变成 fork 风暴），
/// 死亡（被杀/崩溃）后下一次请求自动重拉。
public final class FanHelperClient: FanWriting, @unchecked Sendable {
    /// 开发期默认路径（swift run/测试从包根起跑）；组包后由组合根注入
    /// .app 内 helper 的绝对路径（与 MobileBatteryHelperReader 同约定）。
    public static let defaultHelperPath = ".build/fanhelper/statusbutler-fanhelper"

    /// 单次往返超时：看门狗超时即杀 helper 进程（管道 EOF 解锁阻塞中的读），
    /// 返回失败。看护的故障形态是"helper 卡在 SMC 调用不回头"，等它没有意义。
    public static let roundTripTimeout: TimeInterval = 5

    public let helperPath: String

    /// 串行 IO 域：process/stdin/stdout/reader 只在此队列触碰（@unchecked 的前提）
    private let ioQueue = DispatchQueue(label: "statusbutler.fanhelper.client")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader: PipeLineReader?

    public init(helperPath: String = FanHelperClient.defaultHelperPath) {
        self.helperPath = helperPath
    }

    /// helper 二进制是否在位（讨论"要不要显示安装引导"的判据；
    /// 在位 ≠ 可写——权限/机型问题由首次写往返暴露）。
    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// 协议级存活探测：拉起 helper 发 ping（零 SMC 副作用）。
    /// isInstalled 之外多一道"二进制在且说同一版协议"的确认。
    public func ping() async -> Bool {
        await roundTrip(requestJSON: "{\"action\":\"ping\"}")
    }

    public func write(key: String, value: Int) async -> Bool {
        // 第一道白名单闸（红线二）：非风扇域键在客户端就地拒绝，
        // 不给 helper 送任何让它为难的东西
        guard FanHelperKeys.isWriteAllowed(key: key) else { return false }
        let request = ["action": "set", "key": key, "value": value] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8)
        else { return false }
        return await roundTrip(requestJSON: line)
    }

    public func setMode(_ mode: UInt8) async -> Bool {
        await write(key: FanHelperKeys.modeKey, value: Int(mode))
    }

    public func setRPM(_ rpm: Int, fan: Int) async -> Bool {
        guard let rpmKey = FanHelperKeys.rpmKey(fan: fan) else { return false }
        return await write(key: rpmKey, value: rpm)
    }

    public func restoreSystem() async -> Bool {
        await setMode(FanHelperKeys.systemAutoMode)
    }

    // MARK: - 往返内核

    private func roundTrip(requestJSON: String) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: syncRoundTrip(requestJSON: requestJSON))
            }
        }
    }

    private func syncRoundTrip(requestJSON: String) -> Bool {
        guard ensureProcess() else { return false }

        // 看门狗：超时杀进程。阻塞在 availableData 的读随管道 EOF 解锁返回 false
        let watchdog = DispatchWorkItem { [weak self] in
            self?.teardownProcess()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.roundTripTimeout, execute: watchdog
        )
        defer { watchdog.cancel() }

        guard let stdin = stdinHandle,
              let data = (requestJSON + "\n").data(using: .utf8)
        else {
            teardownProcess()
            return false
        }
        stdin.write(data)
        guard let response = reader?.readLine() else {
            teardownProcess()
            return false
        }
        return Self.responseIsOK(response)
    }

    /// 应答契约：{"ok":true}。其余一切（ok:false/坏 JSON/空行）按失败收敛——
    /// 面板只需要布尔，错误文本留给 helper 的 stderr 与日志侧
    static func responseIsOK(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ok = object["ok"] as? Bool
        else { return false }
        return ok
    }

    /// 惰性拉起 helper；已在役/拉起失败都由返回值一次性表达。
    /// 环境隔离：helper 的 stdin/stderr 不继承本进程（stdout 是协议通道必须接管）。
    private func ensureProcess() -> Bool {
        if let process, process.isRunning { return true }
        teardownProcess()

        guard isInstalled else { return false }  // 未安装 → 诚实 false（面板降级）

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: helperPath)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        newProcess.standardInput = stdinPipe
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = Pipe()  // 诊断不进协议通道；helper 崩溃信息归系统日志
        do {
            try newProcess.run()
        } catch {
            return false
        }
        process = newProcess
        stdinHandle = stdinPipe.fileHandleForWriting
        reader = PipeLineReader(handle: stdoutPipe.fileHandleForReading)
        return true
    }

    private func teardownProcess() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        reader?.close()
        process = nil
        stdinHandle = nil
        reader = nil
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
