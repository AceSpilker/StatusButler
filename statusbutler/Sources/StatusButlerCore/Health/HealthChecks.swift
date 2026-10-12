import Foundation

// E18·HLTH-01/03 系统健康体检：检查器协议 + live 只读实现 + 巡检编排。
// 边界（HLTH-03 只检测不代改）：live 检查仅执行系统"状态查询"命令并解析 stdout，
// 不携带任何修改性子命令；安全设置必须用户亲手改，这是产品原则而非技术限制。
// 命令与参数全部为编译期白名单常量，不含用户输入，不构成任意命令执行面（AU-04 同源纪律）。

public protocol HealthChecking: Sendable {
    var id: String { get }
    func run() -> HealthCheckResult
}

/// 命令输出提供者：live 实现跑系统命令收集 stdout；测试注入假闭包，零系统依赖可全链路验证。
public typealias CommandOutputProvider = @Sendable () throws -> String

public enum HealthCheckError: Error, Equatable {
    case commandFailed(exitCode: Int32)
}

public enum SystemCommand {
    /// 只读诊断执行：fdesetup status / spctl --status / socketfilterfw --getglobalstate / defaults read
    /// 均为查询类命令，不改变任何系统状态；stderr 弃置（判定只依据 stdout）。
    public static func stdout(path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        // 先读后等：输出超管道缓冲时 waitUntilExit 会与子进程写 stdout 互锁
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HealthCheckError.commandFailed(exitCode: process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - FileVault

public struct FileVaultCheck: HealthChecking {
    public static let checkID = "filevault"
    public var id: String { Self.checkID }

    private let collect: CommandOutputProvider

    public init(collect: CommandOutputProvider? = nil) {
        self.collect = collect ?? { try SystemCommand.stdout(path: "/usr/bin/fdesetup", arguments: ["status"]) }
    }

    public func run() -> HealthCheckResult {
        // 命令执行失败（工具缺失/权限受限）按"无法判定"收敛，绝不误报 fail
        guard let stdout = try? collect() else { return Self.evaluate(stdout: "") }
        return Self.evaluate(stdout: stdout)
    }

    /// 纯函数：fdesetup 只有 On/Off 两种已知输出形态，其余一律 notApplicable。
    public static func evaluate(stdout: String) -> HealthCheckResult {
        if stdout.contains("FileVault is On") {
            return HealthCheckResult(id: checkID, title: "FileVault 磁盘加密", status: .pass,
                                     detail: "FileVault 已开启，磁盘数据已加密。", remediationHint: "")
        }
        if stdout.contains("FileVault is Off") {
            return HealthCheckResult(id: checkID, title: "FileVault 磁盘加密", status: .fail,
                                     detail: "FileVault 未开启，磁盘数据处于明文状态。",
                                     remediationHint: "打开 系统设置 → 隐私与安全性 → FileVault，开启磁盘加密。")
        }
        return HealthCheckResult(id: checkID, title: "FileVault 磁盘加密", status: .notApplicable,
                                 detail: "无法读取 FileVault 状态（fdesetup 输出无法识别）。", remediationHint: "")
    }
}

// MARK: - Gatekeeper

public struct GatekeeperCheck: HealthChecking {
    public static let checkID = "gatekeeper"
    public var id: String { Self.checkID }

    private let collect: CommandOutputProvider

    public init(collect: CommandOutputProvider? = nil) {
        self.collect = collect ?? { try SystemCommand.stdout(path: "/usr/sbin/spctl", arguments: ["--status"]) }
    }

    public func run() -> HealthCheckResult {
        guard let stdout = try? collect() else { return Self.evaluate(stdout: "") }
        return Self.evaluate(stdout: stdout)
    }

    /// 纯函数：spctl --status 输出 "assessments enabled" / "assessments disabled"。
    public static func evaluate(stdout: String) -> HealthCheckResult {
        if stdout.contains("assessments enabled") {
            return HealthCheckResult(id: checkID, title: "Gatekeeper 应用来源校验", status: .pass,
                                     detail: "Gatekeeper 已启用，仅允许受信任来源的 App 运行。", remediationHint: "")
        }
        if stdout.contains("assessments disabled") {
            return HealthCheckResult(id: checkID, title: "Gatekeeper 应用来源校验", status: .fail,
                                     detail: "Gatekeeper 已关闭，任意来源 App 可直接运行。",
                                     remediationHint: "打开 系统设置 → 隐私与安全性，将允许的下载来源恢复为 App Store 与已知开发者。")
        }
        return HealthCheckResult(id: checkID, title: "Gatekeeper 应用来源校验", status: .notApplicable,
                                 detail: "无法读取 Gatekeeper 状态（spctl 输出无法识别）。", remediationHint: "")
    }
}

// MARK: - 防火墙

public struct FirewallCheck: HealthChecking {
    public static let checkID = "firewall"
    public var id: String { Self.checkID }

    private let collect: CommandOutputProvider

    public init(collect: CommandOutputProvider? = nil) {
        self.collect = collect ?? {
            try SystemCommand.stdout(path: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"])
        }
    }

    public func run() -> HealthCheckResult {
        guard let stdout = try? collect() else { return Self.evaluate(stdout: "") }
        return Self.evaluate(stdout: stdout)
    }

    /// 纯函数：输出形如 "Firewall is enabled. (State = 1)" / "Firewall is disabled. (State = 0)"。
    /// 关闭只评 warn 不评 fail：家用/受信网络关防火墙常见，属建议级而非硬性风险。
    public static func evaluate(stdout: String) -> HealthCheckResult {
        if stdout.contains("enabled") {
            return HealthCheckResult(id: checkID, title: "防火墙", status: .pass,
                                     detail: "应用防火墙已开启。", remediationHint: "")
        }
        if stdout.contains("disabled") {
            return HealthCheckResult(id: checkID, title: "防火墙", status: .warn,
                                     detail: "应用防火墙未开启。",
                                     remediationHint: "打开 系统设置 → 网络 → 防火墙，开启防火墙。")
        }
        return HealthCheckResult(id: checkID, title: "防火墙", status: .notApplicable,
                                 detail: "无法读取防火墙状态（socketfilterfw 输出无法识别）。", remediationHint: "")
    }
}

// MARK: - 系统更新滞后

/// defaults 只读 LastAttemptSystemVersion（形如 "15.1 (24B83)"），括号内为 build 号；
/// 与当前 sw_vers build 不一致 → 有更新未落地。仅提示级（warn）：可能是尚未重启完成安装，不能定罪为 fail。
public struct SoftwareUpdateCheck: HealthChecking {
    public static let checkID = "softwareUpdate"
    public var id: String { Self.checkID }

    private let readAttempted: CommandOutputProvider
    private let readCurrentBuild: CommandOutputProvider

    public init(attempted: CommandOutputProvider? = nil, currentBuild: CommandOutputProvider? = nil) {
        self.readAttempted = attempted ?? {
            try SystemCommand.stdout(path: "/usr/bin/defaults",
                                     arguments: ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "LastAttemptSystemVersion"])
        }
        self.readCurrentBuild = currentBuild ?? {
            try SystemCommand.stdout(path: "/usr/bin/sw_vers", arguments: ["-buildVersion"])
        }
    }

    public func run() -> HealthCheckResult {
        // defaults read 在键不存在时非零退出：从未检查过更新 → 无法判定
        guard let attempted = try? readAttempted(),
              let current = try? readCurrentBuild() else {
            return Self.evaluate(attemptedOutput: nil, currentBuild: "")
        }
        return Self.evaluate(attemptedOutput: attempted,
                             currentBuild: current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 纯函数：两个输入均为命令原始 stdout（attempted 为 nil 表示从未记录更新检查）。
    public static func evaluate(attemptedOutput: String?, currentBuild: String) -> HealthCheckResult {
        let title = "系统更新"
        guard let attemptedOutput, !attemptedOutput.isEmpty else {
            return HealthCheckResult(id: checkID, title: title, status: .notApplicable,
                                     detail: "尚未记录到系统更新检查结果。", remediationHint: "")
        }
        guard let open = attemptedOutput.firstIndex(of: "("),
              let close = attemptedOutput.lastIndex(of: ")"),
              open < close else {
            return HealthCheckResult(id: checkID, title: title, status: .notApplicable,
                                     detail: "无法解析最近尝试的更新版本。", remediationHint: "")
        }
        let attemptedBuild = attemptedOutput[attemptedOutput.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attemptedBuild.isEmpty else {
            return HealthCheckResult(id: checkID, title: title, status: .notApplicable,
                                     detail: "无法解析最近尝试的更新版本。", remediationHint: "")
        }
        if attemptedBuild == currentBuild {
            return HealthCheckResult(id: checkID, title: title, status: .pass,
                                     detail: "系统已是最近一次尝试安装的版本（\(attemptedBuild)）。", remediationHint: "")
        }
        return HealthCheckResult(id: checkID, title: title, status: .warn,
                                 detail: "最近尝试安装的更新（\(attemptedBuild)）与当前系统（\(currentBuild)）不一致，可能存在未安装完成的更新。",
                                 remediationHint: "打开 系统设置 → 通用 → 软件更新，检查并安装可用更新。")
    }
}

// MARK: - 巡检编排

/// 检查互相独立且只读 → TaskGroup 并发执行；报告仍按注册顺序排列，保证 UI 分区稳定。
public struct HealthAuditor: Sendable {
    public let checks: [any HealthChecking]

    public init(checks: [any HealthChecking]) {
        self.checks = checks
    }

    public func runAll() async -> HealthReport {
        let byIndex = await withTaskGroup(of: (Int, HealthCheckResult).self) { group in
            for (index, check) in checks.enumerated() {
                group.addTask { (index, check.run()) }
            }
            var collected: [Int: HealthCheckResult] = [:]
            for await pair in group {
                collected[pair.0] = pair.1
            }
            return collected
        }
        let results = byIndex.sorted { $0.key < $1.key }.map(\.value)
        return HealthReport(results: results)
    }
}
