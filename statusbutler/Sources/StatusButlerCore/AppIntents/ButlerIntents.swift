import AppIntents
import Foundation

// MARK: - AppIntents 动作（A9 · AU-02，A14-ε）
// Siri / 快捷指令 / 键盘快捷键零配置可用的入口。执行体全部经 SharedIntentExecutor
// 注入（注册-调用模式）：intent 层只负责"参数 → 白名单 ButlerCommand"的翻译，
// 本文件零系统操作——与 ButlerURLRouter/CLIEngine 共用同一张动作真值表（AC-05）。
// verb 越过 parse 直构是安全的：resolve() 对直构命令再过一道白名单（纵深防御，
// 见 ButlerCommand.resolve 的防御说明）。

/// 音量调高（步进）。步进宽度由接线侧决定（读当前音量 + delta，见 AutomationGlue 的接线注记）。
public struct VolumeUpIntent: AppIntent {
    public static let title: LocalizedStringResource = "音量调高"

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SharedIntentExecutor.shared.perform(ButlerCommand(verb: "volume/up")) {
        case .performed:
            return .result(dialog: "音量已调高")
        case .rejected(let reason):
            return .result(dialog: "未执行：\(reason)")
        case .forwardedToApp(let actionID):
            return .result(dialog: "已转交主 App（\(actionID)）")
        }
    }
}

/// 静音切换（toggle 语义与动作中心 AC-02 一致：再执行一次即取消静音）。
public struct VolumeMuteIntent: AppIntent {
    public static let title: LocalizedStringResource = "静音"

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SharedIntentExecutor.shared.perform(ButlerCommand(verb: "volume/mute")) {
        case .performed:
            return .result(dialog: "已切换静音")
        case .rejected(let reason):
            return .result(dialog: "未执行：\(reason)")
        case .forwardedToApp(let actionID):
            return .result(dialog: "已转交主 App（\(actionID)）")
        }
    }
}

/// 打开状态面板（弹层 toggle 也走同一注册执行器——接线侧注册的就是弹层控制器）。
public struct ShowPanelIntent: AppIntent {
    public static let title: LocalizedStringResource = "打开状态面板"

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SharedIntentExecutor.shared.perform(ButlerCommand(verb: "panel/show")) {
        case .performed:
            return .result(dialog: "面板已打开")
        case .rejected(let reason):
            return .result(dialog: "未执行：\(reason)")
        case .forwardedToApp(let actionID):
            return .result(dialog: "已转交主 App（\(actionID)）")
        }
    }
}

/// 音量档位 AppEnum：0-100 十档。档位化而非 0-100 连续整数——快捷指令/Siri 口播场景
/// "设为百分之五十"更可命中，且档位值域即 ButlerCommand volume/set 的合法值域子集，
/// 映射层零换算错误空间。
public enum VolumeStep: Int, AppEnum {
    case off = 0
    case ten = 10
    case twenty = 20
    case thirty = 30
    case forty = 40
    case fifty = 50
    case sixty = 60
    case seventy = 70
    case eighty = 80
    case ninety = 90
    case hundred = 100

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "音量档位")

    public static let caseDisplayRepresentations: [VolumeStep: DisplayRepresentation] = [
        .off: "0%",
        .ten: "10%",
        .twenty: "20%",
        .thirty: "30%",
        .forty: "40%",
        .fifty: "50%",
        .sixty: "60%",
        .seventy: "70%",
        .eighty: "80%",
        .ninety: "90%",
        .hundred: "100%",
    ]
}

/// 设置音量到指定档位（AU-01 volume/set 的 AppIntent 面）。
public struct VolumeSetIntent: AppIntent {
    public static let title: LocalizedStringResource = "设置音量档位"

    @Parameter(title: "档位")
    public var level: VolumeStep

    public init() {}

    public init(level: VolumeStep) {
        self.level = level
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // value 字符串化即白名单校验域（0/10/.../100 全部 ∈ 0...100 整数）
        let command = ButlerCommand(verb: "volume/set", args: ["value": String(level.rawValue)])
        switch await SharedIntentExecutor.shared.perform(command) {
        case .performed:
            return .result(dialog: "音量已设为 \(level.rawValue)%")
        case .rejected(let reason):
            return .result(dialog: "未执行：\(reason)")
        case .forwardedToApp(let actionID):
            return .result(dialog: "已转交主 App（\(actionID)）")
        }
    }
}
