import AppKit

// 遥测首次同意询问（A2·S11·OG-FR-201）：引导完成的同一时机问一次。
// 判定（needsAsk）纯函数；presentDialog 的 NSAlert 只在真机运行路径构造——
// CI / 单测永不触碰（无 WindowServer 的宿主弹模态框会崩，T-032 守卫经验）。

@MainActor
public enum TelemetryFirstConsent {
    /// 仅"从未问过"才问：重启不重问、设置里改过的不打扰——"默认关"的落点是
    /// notAsked ≠ optedIn，不问就永远不发
    public static func needsAsk(current: TelemetryConsent) -> Bool {
        current == .notAsked
    }

    /// 两键模态：分享 = optedIn / 不分享 = optedOut；Esc / Cmd-. 关闭按"未设置"落（保持默认关）
    public static func presentDialog(localization: Localization) -> TelemetryConsent {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localization.string(.telemetryAskTitle)
        alert.informativeText = localization.string(.telemetryAskMessage)
        alert.addButton(withTitle: localization.string(.telemetryOptedIn))
        alert.addButton(withTitle: localization.string(.telemetryOptedOut))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .optedIn
        case .alertSecondButtonReturn: return .optedOut
        default: return .notAsked
        }
    }
}
