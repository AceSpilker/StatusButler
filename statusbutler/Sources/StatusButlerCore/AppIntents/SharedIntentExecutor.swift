import Foundation

// MARK: - AppIntent 执行桥（A9 · AU-02，A14-ε）
// AppIntents 框架要求 intent 是可被系统无参反射构造的值类型，依赖无法随构造注入
// → 执行器走全局注册表：主 App 组合根启动时把 AutomationCoordinator（ActionCenter 绑定）
// 与弹层 toggle 注册进来。纯注册-调用：本类型零系统调用、零路由逻辑——
// 动词白名单与参数校验的唯一真相源仍是 ButlerCommand 层（AC-05 一套动作表喂三处）。
// actor 而非锁类：注册/调用都是异步路径上的短临界区，锁没有额外收益。
public actor SharedIntentExecutor {
    public static let shared = SharedIntentExecutor()

    private var executor: (@Sendable (ButlerCommand) -> ActionOutcome)?

    public init() {}

    public func register(_ executor: @escaping @Sendable (ButlerCommand) -> ActionOutcome) {
        self.executor = executor
    }

    /// 测试出口：恢复"未注册"初始态（测试套件 .serialized 串行执行，逐用例重置避免注册态串味）
    public func resetForTesting() {
        executor = nil
    }

    public func perform(_ command: ButlerCommand) -> ActionOutcome {
        guard let executor else {
            // 诚实拒绝（AC-02 精神）：主 App 没接线时，Siri/快捷指令收到的是"未接线"
            // 而非伪装成功——用户至少知道去开主 App
            return .rejected(reason: "AppIntent 执行器未注册（主 App 组合根接线后可用）")
        }
        return executor(command)
    }
}
