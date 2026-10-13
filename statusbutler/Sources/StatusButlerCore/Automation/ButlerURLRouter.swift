import Foundation

// T-052: butler:// URL 事件总线（A9·AU-01）。T-034 的 ActionCenter.perform(url:) 为薄调用方
// 把"非本家 scheme"折成 nil、"解析被拒"折成 ActionOutcome.rejected(reason:)——链路一长就分不清
// "参数被拒"与"执行器拒绝"。URL 入口恰恰需要这个区分：AU-01 的静默日志要消费结构化 CommandError
// （CLI 侧还要据此分流退出码 1/3），多 scheme 场景更要拿 notOurs 把事件原样交还系统。
// 本路由因此只做"解包"：解析复用 ButlerCommand.parse，执行全权委托注入的 ActionCenter，
// 自身零状态、零 IO——AU-01 的"记日志"由挂日志系统的集成方完成（Core 层无 Logger 依赖）。

/// URL 路由三态结果
public enum URLRouteOutcome: Equatable, Sendable {
    /// butler:// 命令已进执行器；执行成败（含执行器侧拒绝）都封装在 ActionOutcome 里上抛
    case handled(ActionOutcome)
    /// 非 butler:// scheme——不归我们管。调用方必须原样交还系统，绝不能吞掉其他 App 的事件
    case notOurs
    /// 白名单/参数校验层拒绝。AU-01 语义：静默记日志、不弹窗、不退出；结构化 CommandError
    /// 供调用方日志与 CLI 退出码分流（unknownCommand→1 / invalidValue、forbidden→3）
    case rejected(CommandError)
}

/// butler:// URL 事件总线：把系统递来的 URL 分拣成三态。
///
/// ## AppDelegate 集成建议（挂 AppKit 的 URL 事件回调；SwiftUI 场景用 `.onOpenURL` 等价挂载）
///
///     @MainActor
///     extension AppDelegate {
///         func application(_ application: NSApplication, open urls: [URL]) {
///             let router = ButlerURLRouter()
///             for url in urls {
///                 switch router.handle(url: url, executor: actionCenter) {  // actionCenter 来自组合根
///                 case .notOurs:
///                     continue  // 非 butler://——交还系统，不吞事件
///                 case .rejected(let error):
///                     logger.info("butler:// 拒绝：\(error.summary)")  // AU-01：静默日志，不弹窗
///                 case .handled(let outcome):
///                     logger.info("butler:// 结果：\(outcome)")
///                 }
///             }
///         }
///     }
///
/// 前提：主 App 的 Info.plist（Support/Info.plist，组包时拷入 .app）注册 CFBundleURLTypes
/// 声明 `butler` scheme，否则系统根本不会把 butler:// 事件投递到本进程——注册片段见 T-052 任务报告。
public struct ButlerURLRouter: Sendable {
    public init() {}

    /// 单个 URL 事件入口。executor 为注入的动作中心（可用性/权限裁决全在其执行器内，本层不替它决定）
    public func handle(url: URL, executor: ActionCenter) -> URLRouteOutcome {
        guard let parsed = ButlerCommand.parse(url) else { return .notOurs }
        switch parsed {
        case .success(let command):
            return .handled(executor.perform(command))
        case .failure(let error):
            // AU-01：拒绝即静默——不弹窗、不中断、不产生任何副作用；"记日志"留给集成方，
            // 本层只负责把拒绝原因结构化上抛（不丢 CommandError，调用方才有分流依据）
            return .rejected(error)
        }
    }
}

extension URLRouteOutcome {
    /// 非 URL 语境（面板/Intent）统一折算成 ActionOutcome
    public var forceOutcome: ActionOutcome {
        switch self {
        case .handled(let outcome): return outcome
        case .notOurs, .rejected: return .rejected(reason: "命令未路由或被拒")
        }
    }
}
