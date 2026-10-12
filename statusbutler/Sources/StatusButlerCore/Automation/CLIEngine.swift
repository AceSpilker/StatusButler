import Foundation

// T-052: statusbutler CLI 引擎（A9·AU-03）。Core 层纯逻辑：不碰 Process/CommandLine、不做 IO——
// stdout/stderr 与 exit 由未来可执行 target 的薄壳 main 消费 CLIOutcome 完成；动词面全部复用
// ButlerCommand.parse(arguments:)（AU-01 白名单同源，AC-05），本引擎零新增命令。
// 快照直读不经执行器（AU-04：status 是唯一只读动词，查询零副作用、不落系统）。

/// CLI 运行结果：薄壳 main 的全部输出协议。
/// - `printed`：stdout 文本（成功路径，退出码恒 0）。
/// - `exitCode`：无 stdout 载荷的终止码（1/2/3，规约表见 `CLIEngine.exitCode`）。
/// 错误明细不上 stdout——脚本只认"码 + 成功 JSON"两个契约，错误 JSON/人话由薄壳按码与 argv
/// 呈现（码 2 在 --json 模式打 `appNotRunningJSON` 到 stdout、人类模式打一行提示到 stderr）。
public enum CLIOutcome: Equatable {
    case printed(String)
    case exitCode(Int32)
}

/// 命令行引擎（供未来 statusbutler 可执行 target 复用）。
///
/// ## 可执行 target 挂载建议（薄壳 main，转发 URL Scheme 到主 App 是 AU-03 的主形态）
///
///     @main
///     enum StatusButlerCLI {
///         static func main() {
///             let outcome = CLIEngine.run(
///                 arguments: Array(CommandLine.arguments.dropFirst()),
///                 snapshotReader: { WidgetSnapshotWriter().read() },        // 快照文件容错读（nil = 未运行）
///                 actionExecutor: { command in forwardButlerURL(command) } // 拼但不上 butler:// 打给主 App
///             )
///             switch outcome {
///             case .printed(let text):
///                 print(text)
///                 exit(CLIEngine.exitCode(for: outcome))  // printed 恒 0
///             case .exitCode(let code):
///                 if code == CLIEngine.snapshotUnavailableCode, wantsJSON {
///                     print(CLIEngine.appNotRunningJSON)  // --json 模式：脚本统一按 JSON 解析 stdout
///                 }
///                 exit(code)
///             }
///         }
///     }
public enum CLIEngine {
    // MARK: - 运行

    /// 参数表不含程序名（与 ButlerCommand.parse(arguments:) 同约定，调用方 dropFirst 后传入）。
    /// 空参数表与 `--help` / `-h` / `help` 一律给速查文本（交互友好，退出码 0）——帮助是仅有的
    /// "白名单外"入口，其余一切非白名单形状走 1/3 码，命令面只减不增。
    public static func run(
        arguments: [String],
        snapshotReader: () -> WidgetSnapshot?,
        actionExecutor: (ButlerCommand) -> ActionOutcome
    ) -> CLIOutcome {
        guard let first = arguments.first else { return .printed(helpText) }
        if first == "--help" || first == "-h" || first == "help" { return .printed(helpText) }

        guard let parsed = ButlerCommand.parse(arguments: arguments) else {
            return .printed(helpText)  // parse 仅对空表返回 nil，上方已兜住；防御不可达路径
        }
        switch parsed {
        case .failure(let error):
            return .exitCode(exitCode(for: error))
        case .success(let command):
            if command.verb == "status" {
                guard let snapshot = snapshotReader() else { return .exitCode(snapshotUnavailableCode) }
                if command.args["json"] == "true" {
                    // 编码失败与读不到同归码 2：CLI 对外只有"能不能交付状态"一个口径
                    guard let text = jsonText(snapshot) else { return .exitCode(snapshotUnavailableCode) }
                    return .printed(text)
                }
                return .printed(humanText(snapshot))
            }
            let outcome = actionExecutor(command)
            switch outcome {
            case .performed:
                return .printed("已执行：\(commandLabel(command))")
            case .forwardedToApp(let actionID):
                // 薄壳转发形态（AU-03）：送达即成功——主 App 内部成败对 CLI 进程不可见
                return .printed("已转发到主 App：\(actionID)")
            case .rejected:
                // 拒绝明细由薄壳按需打 stderr；引擎只交付规约码（stdout 契约零噪音）
                return .exitCode(exitCode(for: outcome))
            }
        }
    }

    // MARK: - 退出码规约（AU-03 全表；薄壳 main 与测试共用同一张表，杜绝两处漂移）
    // 0 成功 / 1 未知命令 / 2 快照不可用（主 App 未运行或未产出首帧）/ 3 被拒（参数非法或执行器拒绝）

    /// 快照不可用码（status 家族专属失败类）
    public static let snapshotUnavailableCode: Int32 = 2

    /// 运行结果 → 码：printed 一律 0；exitCode 原样透传
    public static func exitCode(for outcome: CLIOutcome) -> Int32 {
        switch outcome {
        case .printed: return 0
        case .exitCode(let code): return code
        }
    }

    /// 解析/校验错误 → 码：白名单外动词 1（未知命令）；参数缺失/越界/规格外 3（被拒）。
    /// AU-01 两类拒绝对脚本必须可分：白名单面问题（1）与参数面问题（3）修法完全不同
    public static func exitCode(for error: CommandError) -> Int32 {
        switch error {
        case .unknownCommand: return 1
        case .invalidValue, .forbidden: return 3
        }
    }

    /// 执行器结果 → 码：已执行/已转发 0；执行器拒绝（权限/可用性裁决）3
    public static func exitCode(for outcome: ActionOutcome) -> Int32 {
        switch outcome {
        case .performed, .forwardedToApp: return 0
        case .rejected: return 3
        }
    }

    /// 快照不可用时的标准错误载荷（--json 模式，薄壳在码 2 时打到 stdout）：
    /// 脚本对 stdout 永远按 JSON 解析，成功失败一个形态。契约字符串手写钉死——
    /// 跨进程/跨语言契约不依赖编译器合成的编码形态（同 WidgetSnapshotModels 的纪律）。
    public static let appNotRunningJSON = #"{"error":"app-not-running"}"#

    // MARK: - 速查文本

    /// 白名单段从 ButlerCommand.allowed 现算——帮助永不与白名单漂移（AC-05 同源）；
    /// 上方手写段只是排版示例，权威表是自动段
    public static let helpText: String = {
        var lines: [String] = [
            "statusbutler — 状态管家命令行（AU-03；动词与 butler:// 同源，AU-01/AC-05）",
            "",
            "用法：statusbutler <动词> [参数]",
            "",
            "命令：",
            "  status [--json]                       当前状态快照（--json 输出机器可读 JSON）",
            "  volume up|down|mute                   音量步进 / 静音",
            "  volume set <0-100>（捷径：volume 50） 设定音量",
            "  mute                                  静音（单字捷径）",
            "  panel show|thermal|battery|network    打开面板 / 直达分区",
            "  bluetooth connect <设备名>             连接蓝牙设备",
            "  fan auto|max                          风扇恢复自动 / 全速应急",
            "  fan rpm <1000-15000>（捷径：fan 4000）恒定转速",
            "  slot cycle                            槽位轮换",
            "  theme apply <主题名>                   应用主题",
            "  screen off                            熄屏",
            "",
            "选项：--help | -h | help                显示本帮助",
            "",
            "白名单动词（自动生成自 ButlerCommand.allowed）：",
        ]
        lines.append(contentsOf: ButlerCommand.allowed.sorted().map { "  \($0)" })
        lines.append(contentsOf: [
            "",
            "退出码：0 成功 / 1 未知命令 / 2 快照不可用（主 App 未运行）/ 3 被拒（参数或权限）",
            "命令速查卡片见设置页（AU-05）。",
        ])
        return lines.joined(separator: "\n")
    }()

    // MARK: - status 输出

    /// 人类可读多行。nil 域显示 "—"：快照契约里 nil = 主 App 尚未产出该域，不是 0——绝不伪装
    static func humanText(_ snapshot: WidgetSnapshot) -> String {
        var lines: [String] = [
            "状态管家 · 当前快照",
            "生成时间：\(formatTimestamp(snapshot.generatedAt))",
        ]
        switch snapshot.battery {
        case .none:
            lines.append("电池：—")
        case .some(.unavailable):
            lines.append("电池：不可用")
        case .some(.battery(let level, let charging)):
            lines.append("电池：\(level)%（\(charging ? "充电中" : "未充电")）")
        }
        switch snapshot.link {
        case .none:
            lines.append("网络：—")
        case .some(.offline):
            lines.append("网络：离线")
        case .some(.wired):
            lines.append("网络：有线")
        case .some(.wifi(let ssid, let bars)):
            // 信号格口径 0...4，与图标渲染端（点=1格、三弧=2/3/4格）同源
            lines.append("网络：Wi-Fi \(ssid ?? "未知网络")（信号 \(bars)/4）")
        }
        if let volume = snapshot.volume {
            lines.append("音量：\(volume.level)%\(volume.isMuted ? "（静音中）" : "")")
        } else {
            lines.append("音量：—")
        }
        lines.append(snapshot.maxCelsius.map { String(format: "最高温度：%.1f°C", $0) } ?? "最高温度：—")
        lines.append(snapshot.fanAverageRPM.map { "风扇均速：\($0) RPM" } ?? "风扇均速：—")
        if let rates = snapshot.netBytesPerSec {
            lines.append("网速：入 \(formatBytesPerSec(rates.in)) · 出 \(formatBytesPerSec(rates.out))")
        } else {
            lines.append("网速：—")
        }
        return lines.joined(separator: "\n")
    }

    /// 机器可读 JSON（Codable 直出）。默认编码策略、零自定义配置——Date 走参考时间戳 Double，
    /// 任意语言的标准 JSON 解码器无配置即可解回；键排序稳定便于 diff
    static func jsonText(_ snapshot: WidgetSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 网络速率十进制单位（网络域行业口径 1 MB/s = 1,000,000 B/s，不是 1024 进位）。
    /// String(format:) 不做本地化小数点——输出确定性优先
    static func formatBytesPerSec(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }

    /// 时间戳固定 zh_CN + 本机时区：给人看的行不进测试断言（测试只锚内容行），确定性无虞。
    /// formatter 即建即弃——CLI 是一次性进程，不值得为复用引入静态非 Sendable 状态
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 成功回执：动词 + 键排序参数（volume/set value=50）。确定性输出，日志与测试可直接锚
    static func commandLabel(_ command: ButlerCommand) -> String {
        let args = command.args
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return args.isEmpty ? command.verb : "\(command.verb) \(args)"
    }
}
