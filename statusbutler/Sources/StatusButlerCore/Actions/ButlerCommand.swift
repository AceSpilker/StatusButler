import Foundation

// T-034: butler:// URL Scheme（A9·AU-01）与 statusbutler CLI（AU-03）的统一命令解析层。
// 安全红线（A2·S12 / AU-04）：动词白名单 + 参数严格校验 + 白名单外一律拒绝；
// 本文件纯逻辑——不拼 shell、不碰 Process，执行永远发生在主 App 注入的 ActionExecutor。

/// 解析/校验错误（AU-01：拒绝即静默忽略并记日志，不弹窗；summary 供日志直接消费）
public enum CommandError: Error, Equatable, Sendable {
    /// 白名单外动词
    case unknownCommand(String)
    /// 必填参数缺失 / 非整数 / 越界
    case invalidValue(parameter: String, value: String)
    /// 动词合法但携带不被接受的参数（最小参数面原则）
    case forbidden(String)

    public var summary: String {
        switch self {
        case .unknownCommand(let verb):
            return "未知命令：\(verb)"
        case .invalidValue(let parameter, let value):
            return "参数非法：\(parameter)=\(value)"
        case .forbidden(let reason):
            return reason
        }
    }
}

public struct ButlerCommand: Equatable, Sendable {
    /// 完整动词（域/限定词），如 "volume/set"——取值域即 ButlerCommand.allowed
    public var verb: String
    /// 已解码参数（URL query 百分号解码后 / CLI 位置参数归位后）
    public var args: [String: String]

    public init(verb: String, args: [String: String] = [:]) {
        self.verb = verb
        self.args = args
    }

    // MARK: - 白名单（AU-01 命令表；"status" 为 AU-03 只读项，仅查询不落系统）

    public static let allowed: Set<String> = [
        "volume/up", "volume/down", "volume/mute", "volume/set",
        "panel/show", "panel/thermal", "panel/battery", "panel/network",
        "bluetooth/connect",
        "fan/auto", "fan/max", "fan/rpm",
        "slot/cycle",
        "theme/apply",
        "screen/off",
        "status",
    ]

    // MARK: - 参数规格与校验

    /// 每个白名单动词期望的参数形态；规格外参数名一律 forbidden（命令面只减不增）
    private enum ParamSpec {
        case noParams
        case int(parameter: String, min: Int, max: Int)
        case text(parameter: String)
        case flags(Set<String>)
    }

    private static let specs: [String: ParamSpec] = [
        "volume/up": .noParams,
        "volume/down": .noParams,
        "volume/mute": .noParams,
        "volume/set": .int(parameter: "value", min: 0, max: 100),
        "panel/show": .noParams,
        "panel/thermal": .noParams,
        "panel/battery": .noParams,
        "panel/network": .noParams,
        "bluetooth/connect": .text(parameter: "device"),
        "fan/auto": .noParams,
        "fan/max": .noParams,
        "fan/rpm": .int(parameter: "value", min: 1000, max: 15000),
        "slot/cycle": .noParams,
        "theme/apply": .text(parameter: "name"),
        "screen/off": .noParams,
        "status": .flags(["json"]),
    ]

    private static func validate(_ verb: String, _ args: [String: String]) -> CommandError? {
        guard let spec = specs[verb] else { return .unknownCommand(verb) }  // 规格表缺失按未知处理（纵深防御）
        switch spec {
        case .noParams:
            guard args.isEmpty else {
                return .forbidden("\(verb) 不接受参数：\(args.keys.sorted().joined(separator: ","))")
            }
        case .int(let parameter, let min, let max):
            if let extra = unexpected(args, allowed: [parameter]) {
                return .forbidden("\(verb) 不支持的参数：\(extra)")
            }
            guard let raw = args[parameter] else {
                return .invalidValue(parameter: parameter, value: "")
            }
            guard let value = Int(raw), (min...max).contains(value) else {
                return .invalidValue(parameter: parameter, value: raw)
            }
        case .text(let parameter):
            if let extra = unexpected(args, allowed: [parameter]) {
                return .forbidden("\(verb) 不支持的参数：\(extra)")
            }
            guard let raw = args[parameter], !raw.isEmpty else {
                return .invalidValue(parameter: parameter, value: "")
            }
        case .flags(let allowedFlags):
            if let extra = unexpected(args, allowed: allowedFlags) {
                return .forbidden("\(verb) 不支持的参数：\(extra)")
            }
        }
        return nil
    }

    private static func unexpected(_ args: [String: String], allowed: Set<String>) -> String? {
        let extra = Set(args.keys).subtracting(allowed).sorted()
        return extra.isEmpty ? nil : extra.joined(separator: ",")
    }

    // MARK: - URL Scheme 解析（butler://）

    /// 非 butler scheme 返回 nil（不归我们管，调用方原样交还系统）；
    /// 归我们管但被白名单/校验拒绝 → .failure（调用方静默记日志，AU-01 无弹窗）
    public static func parse(_ url: URL) -> Result<ButlerCommand, CommandError>? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "butler" else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        // 深路径（host/a/b）不属于任何白名单形态，整体按未知命令拒绝
        guard segments.count <= 1 else {
            return .failure(.unknownCommand((components.host ?? "") + components.path))
        }
        let root = components.host ?? ""
        // 动词大小写不敏感：URL host 解析自带小写，path 侧再兜一层
        let verb = segments.first.map { "\(root)/\($0)".lowercased() } ?? root.lowercased()
        guard allowed.contains(verb) else { return .failure(.unknownCommand(verb)) }
        var args: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // queryItems 已完成百分号解码（device=AirPods%20Pro → "AirPods Pro"）
            args[item.name] = item.value ?? ""
        }
        if let error = validate(verb, args) { return .failure(error) }
        return .success(ButlerCommand(verb: verb, args: args))
    }

    // MARK: - CLI 解析（statusbutler，AU-03；参数表不含程序名，调用方 dropFirst 后传入）

    /// 空参数表返回 nil（无命令可执行）；首参数非白名单动词域 → unknownCommand。
    /// 数值捷径：volume 50 → volume/set value=50、fan 4000 → fan/rpm value=4000
    public static func parse(arguments: [String]) -> Result<ButlerCommand, CommandError>? {
        guard let first = arguments.first else { return nil }
        var flags: [String: String] = [:]
        var positionals: [String] = []
        for token in arguments.dropFirst() {
            if token.hasPrefix("--"), token.count > 2 {
                flags[String(token.dropFirst(2))] = "true"
            } else {
                positionals.append(token)
            }
        }

        // 动词组装：根词 + 限定词
        let root = first.lowercased()
        let verb: String
        var paramTokens: [String]
        switch root {
        case "mute":  // 静音单字捷径
            verb = "volume/mute"
            paramTokens = positionals
        case "status":
            verb = "status"
            paramTokens = positionals
        case "volume", "fan":
            guard let head = positionals.first else { return .failure(.unknownCommand(root)) }
            if Int(head) != nil {
                verb = root == "volume" ? "volume/set" : "fan/rpm"
                paramTokens = positionals
            } else {
                verb = "\(root)/\(head.lowercased())"
                paramTokens = Array(positionals.dropFirst())
            }
        case "panel", "bluetooth", "slot", "theme", "screen":
            guard let head = positionals.first else { return .failure(.unknownCommand(root)) }
            verb = "\(root)/\(head.lowercased())"
            paramTokens = Array(positionals.dropFirst())
        default:
            return .failure(.unknownCommand(root))
        }

        guard allowed.contains(verb) else { return .failure(.unknownCommand(verb)) }

        // 位置参数按动词规格归位；多余位置参数直接 forbidden
        var args = flags
        if let spec = specs[verb] {
            switch spec {
            case .int(let parameter, _, _), .text(let parameter):
                guard let value = paramTokens.first else {
                    return .failure(.invalidValue(parameter: parameter, value: ""))
                }
                args[parameter] = value
                guard paramTokens.count == 1 else {
                    return .failure(.forbidden("\(verb) 多余参数：\(paramTokens.dropFirst().joined(separator: " "))"))
                }
            case .noParams, .flags:
                guard paramTokens.isEmpty else {
                    return .failure(.forbidden("\(verb) 多余参数：\(paramTokens.joined(separator: " "))"))
                }
            }
        }
        if let error = validate(verb, args) { return .failure(error) }
        return .success(ButlerCommand(verb: verb, args: args))
    }

    // MARK: - 路由（AC-05：命令与面板动作同源）

    /// 白名单命令 → 注册动作 id。fan/auto 与 fan/max 同归"风扇全速应急"
    /// （AC-02 一行两态：应急/恢复自动是同一动作）；键域与 allowed 一致（测试钉死），白名单命令不落空
    private static let commandTargets: [String: String] = [
        "volume/up": "volume",
        "volume/down": "volume",
        "volume/set": "volume",
        "volume/mute": "mute",
        "panel/show": "panel",
        "panel/thermal": "panel",
        "panel/battery": "panel",
        "panel/network": "panel",
        "bluetooth/connect": "bluetooth-connect",
        "fan/auto": "fan-max",
        "fan/max": "fan-max",
        "fan/rpm": "fan-max",
        "slot/cycle": "slot-cycle",
        "theme/apply": "theme",
        "screen/off": "screen-off",
        "status": "status",
    ]

    /// 纯路由：白名单外一律 rejected（parse 已挡一道，这里防御直构命令绕过解析）；
    /// 参数校验在 parse 完成，可用性/权限裁决在注入的执行器
    public static func resolve(_ command: ButlerCommand) -> ActionOutcome {
        guard allowed.contains(command.verb), let actionID = commandTargets[command.verb] else {
            return .rejected(reason: CommandError.unknownCommand(command.verb).summary)
        }
        return .forwardedToApp(actionID: actionID)
    }
}
