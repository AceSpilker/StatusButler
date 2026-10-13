import AppKit

/// 自动化协调器（T-052 集成半场）：装配 ActionCenter + ButlerURLRouter，
/// 并提供 AutomationStore 的真实系统落点（AppleScript set volume，公开无需辅助功能）
public final class AutomationCoordinator: @unchecked Sendable {
    public let router = ButlerURLRouter()
    private let center: ActionCenter

    private struct SystemStore: AutomationStore {
        func setVolume(level: Int) -> ActionOutcome {
            let clamped = min(max(level, 0), 100)
            let script = NSAppleScript(source: "set volume output volume \(clamped)")
            return script?.executeAndReturnError(nil) == nil
                ? .performed
                : .rejected(reason: "AppleScript set volume 失败")
        }

        func toggleMute() -> ActionOutcome {
            let script = NSAppleScript(source: "set volume output muted (not (output muted))")
            return script?.executeAndReturnError(nil) == nil
                ? .performed
                : .rejected(reason: "AppleScript mute 失败")
        }
    }

    public init() {
        let bindings = AutomationGlue.executorBindings(store: SystemStore())
        center = ActionCenter(executor: { action, command in
            bindings[action.id]?(command) ?? .rejected(reason: "动作未注册：\(action.id)")
        })
    }

    /// AppIntents/CLI 同源入口：command → butler:// 路由
    @discardableResult
    public func performCommand(_ command: ButlerCommand) -> ActionOutcome {
        var c = URLComponents()
        c.scheme = "butler"
        c.host = command.verb
        if !command.args.isEmpty {
            c.queryItems = command.args.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = c.url else { return .rejected(reason: "bad command") }
        return router.handle(url: url, executor: center).forceOutcome
    }

    /// 面板动作行 / AppIntents 共用入口：action.id → butler:// 路由
    @discardableResult
    public func performAction(_ action: ButlerAction) -> ActionOutcome {
        var c = URLComponents()
        c.scheme = "butler"
        c.host = action.id
        guard let url = c.url else { return .rejected(reason: "bad action id: \(action.id)") }
        return router.handle(url: url, executor: center).forceOutcome
    }

    /// URL 事件入口（AppDelegate application(_:open:) 逐个投递）
    @discardableResult
    public func handle(url: URL) -> URLRouteOutcome {
        router.handle(url: url, executor: center)
    }
}
