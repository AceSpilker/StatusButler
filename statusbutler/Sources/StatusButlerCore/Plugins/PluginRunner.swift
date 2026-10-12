import Darwin
import Foundation

// E16·SP-02：沙盒执行引擎。四条硬边界全部在此落实：
// 独立 Process + sandbox-exec 包裹（禁网络/禁写、唯一输出文件豁免）、
// 环境变量清空（只传 LANG）、超时杀灭（整棵进程树）、三连击自动停用。
// 插件来源是用户主动放置的本地脚本，引擎自身零网络。

/// 沙盒执行器。跨插件共享（失败计数按 plugin id 隔离）。
///
/// 锁纪律：唯一可变态 `failureCounts` 由 `lock` 保护，所有读写必须在锁内；
/// `run()` 执行路径不触碰其他共享状态，因此 `@unchecked Sendable` 是安全的。
/// 不用 actor：超时杀灭需要同步轮询 + `waitUntilExit()`（阻塞式），
/// 放进 actor 会把阻塞扩散到调用方隔离域。
public final class PluginRunner: @unchecked Sendable {
    /// SP-02 规定默认 2s：脚本只做轻量状态输出，2s 内跑不完即视为失控。
    public static let defaultTimeout: TimeInterval = 2.0
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    public let timeout: TimeInterval

    private let lock = NSLock()
    private var failureCounts: [String: Int] = [:]

    public init(timeout: TimeInterval = PluginRunner.defaultTimeout) {
        self.timeout = timeout
    }

    /// 三连击规则（纯函数）：连续失败/超时满 3 次即自动停用。
    public static func shouldDisable(failures: Int) -> Bool { failures >= 3 }

    public func failureCount(pluginID: String) -> Int {
        lock.withLock { failureCounts[pluginID] ?? 0 }
    }

    /// 手动复位（设置页"重新启用"入口），同时是停用后的唯一恢复通道。
    public func reset(pluginID: String) {
        lock.withLock { failureCounts[pluginID] = 0 }
    }

    public func run(manifest: PluginManifest, scriptPath: String) async -> PluginOutput {
        // Process 等待/轮询是阻塞式系统调用，不能留在协作线程池 → 丢独立线程
        await Task.detached(priority: .utility) {
            self.runSync(manifest: manifest, scriptPath: scriptPath)
        }.value
    }

    // MARK: - 执行主流程（阻塞式，仅在独立线程调用）

    private func runSync(manifest: PluginManifest, scriptPath: String) -> PluginOutput {
        let id = manifest.id
        // 已停用插件零成本短路，不再 fork
        if Self.shouldDisable(failures: failureCount(pluginID: id)) {
            return .disabled
        }
        // 红线防御：白名单在引擎侧二次校验——目录扫描已过滤，
        // 但引擎不信任任何调用方（纵深防御，任一层被绕过都不至于放行任意解释器）
        guard manifest.isValid, manifest.isInterpreterAllowed else {
            return recordFailure(id, .failed("invalid manifest: interpreter not whitelisted"))
        }
        guard FileManager.default.isReadableFile(atPath: scriptPath) else {
            return recordFailure(id, .failed("script not readable: \(scriptPath)"))
        }

        let fm = FileManager.default
        // 唯一可写豁免：输出文件路径必须 canonical 化（realpath），不能用
        // resolvingSymlinksInPath——后者不解析 /var→/private/var（firmlink），
        // 而沙盒内核按真实路径匹配 subpath，实测 /var 形式会使唯一可写豁免整体落空。
        // realpath 只解析已存在的路径段，故先创建空文件再取真实路径。
        let rawOutputPath = fm.temporaryDirectory
            .appendingPathComponent("StatusButler-plugin-\(UUID().uuidString).out")
            .path
        guard
            fm.createFile(atPath: rawOutputPath, contents: nil),
            let outputPath = Self.realpath(rawOutputPath)
        else {
            return recordFailure(id, .failed("cannot create temp output file"))
        }
        defer { try? fm.removeItem(atPath: outputPath) }

        let process = Process()
        let stderrSink = OutputSink()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 排空子进程输出：脚本诊断噪声不得污染宿主控制台；
        // 不能用 /dev/null——沙盒禁写下 echo 也会 EPERN
        drain(stdoutPipe.fileHandleForReading)
        collect(stderrPipe.fileHandleForReading, into: stderrSink)

        if fm.isExecutableFile(atPath: Self.sandboxExecPath) {
            process.executableURL = URL(fileURLWithPath: Self.sandboxExecPath)
            process.arguments = [
                "-p", PluginSandbox.sandboxProfile(allowWrite: outputPath),
                manifest.interpreter, scriptPath, outputPath,
            ]
        } else {
            // 降级路径：sandbox-exec 在未来 macOS 若被移除，退为无沙盒标记 + 严格超时兜底。
            // 此分支正常不触达（当前 macOS 实测可用），集成方应以日志监控其出现。
            process.executableURL = URL(fileURLWithPath: manifest.interpreter)
            process.arguments = [scriptPath, outputPath]
        }
        // 环境清空：只传 LANG（解码 UTF-8 输出用）。不透传 HOME/PATH 等——
        // 防脚本借宿主环境摸到代理设置、开发目录等上下文。
        process.environment = ["LANG": "en_US.UTF-8"]

        do {
            try process.run()
        } catch {
            return recordFailure(id, .failed("launch failed: \(error.localizedDescription)"))
        }

        // 竞速等待：50ms 心跳轮询比 DispatchSourceTimer 少一层挂载簿记，
        // 且杀灭前需要先快照活的进程树（见 killProcessTree），轮询节奏天然契合
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            // SIGKILL 整棵树：只杀直接子进程会留下孤儿（sh 的 sleep 子进程会被
            // reparent 到 launchd 继续跑），实测验证过，故必须按树杀
            Self.killProcessTree(rootPID: process.processIdentifier)
            process.waitUntilExit()
            finishPipes(stdout: stdoutPipe, stderr: stderrPipe)
            return recordFailure(id, .timeout)
        }

        process.waitUntilExit()
        finishPipes(stdout: stdoutPipe, stderr: stderrPipe)
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            return recordFailure(id, .failed("exit(\(process.terminationStatus)) \(stderrSink.snippet)"))
        }

        guard let data = fm.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8),
              let scene = PluginProtocol.parseScene(output: text)
        else {
            return recordFailure(id, .failed("empty or unparsable protocol output"))
        }
        lock.withLock { failureCounts[id] = 0 }   // 成功清零连败
        return .success(scene)
    }

    private func recordFailure(_ id: String, _ output: PluginOutput) -> PluginOutput {
        lock.withLock { failureCounts[id, default: 0] += 1 }
        return output
    }

    /// POSIX realpath(3)，第二参传 nil 由实现分配缓冲（POSIX.1-2008）。
    /// 供沙盒 subpath 用：内核按 /private/var、/private/tmp 等真实路径匹配。
    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func drain(_ handle: FileHandle) {
        handle.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }   // EOF 自摘
        }
    }

    private func collect(_ handle: FileHandle, into sink: OutputSink) {
        handle.readabilityHandler = { [sink] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
            } else {
                sink.append(chunk)
            }
        }
    }

    /// 进程退出后手动收口 handler：正常退出但仍有孤儿后代持有管道写端时，
    /// EOF 永不到来，handler 必须由宿主侧解除（防泄漏/防循环引用）。
    private func finishPipes(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - 进程树杀灭

    /// 杀根前先快照子孙：根死后子孙被 reparent 到 launchd，ppid 链断裂就再也找不到。
    /// 快照→杀之间存在 PID 复用的理论窗口，但插件超时杀灭是毫秒级动作、
    /// macOS PID 顺序分配，风险量级远低于杀不死孤儿进程的确定性泄漏，故接受。
    private static func killProcessTree(rootPID: pid_t) {
        guard rootPID > 1 else { return }
        var victims: Set<pid_t> = []
        var frontier: Set<pid_t> = [rootPID]
        for _ in 0..<16 {   // 深度上限：防御异常拓扑（fork 炸弹等）
            let children = directChildren(of: frontier, excluding: victims)
            if children.isEmpty { break }
            victims.formUnion(children)
            frontier = children
        }
        kill(rootPID, SIGKILL)
        let selfPID = getpid()
        for pid in victims where pid > 1 && pid != selfPID {
            kill(pid, SIGKILL)
        }
    }

    private static func directChildren(of parents: Set<pid_t>, excluding seen: Set<pid_t>) -> Set<pid_t> {
        var result: Set<pid_t> = []
        for proc in processTable() where parents.contains(proc.ppid) {
            if proc.pid > 1, proc.pid != getpid(), !seen.contains(proc.pid) {
                result.insert(proc.pid)
            }
        }
        return result
    }

    /// 全进程表 (pid, ppid)。sysctl 两次调用间进程表可能增删导致缓冲不足，重试三次。
    private static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            if sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0 {
                let count = size / MemoryLayout<kinfo_proc>.stride
                return (0..<count).map { (buffer[$0].kp_proc.p_pid, buffer[$0].kp_eproc.e_ppid) }
            }
        }
        return []
    }
}

/// stderr 限幅累积器（诊断摘要用，非完整日志）。
/// 锁纪律：`bytes` 由 `lock` 保护；readabilityHandler 在任意队列回调。
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let byteLimit = 4096

    func append(_ data: Data) {
        lock.withLock {
            if bytes.count < byteLimit { bytes.append(data) }
        }
    }

    /// 失败消息里最多带 200 字符，防止坏插件用 stderr 刷屏
    var snippet: String {
        lock.withLock { String(data: bytes.prefix(200), encoding: .utf8) ?? "" }
    }
}
