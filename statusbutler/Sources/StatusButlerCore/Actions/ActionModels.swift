import Foundation

// T-034: 动作中心模型（A9·AC-02~05）—— 一套动作表喂三处：面板按钮 / butler:// 命令 / CLI。
// 纯值类型 + 零系统调用；执行只经主 App 注入的 ActionExecutor（AU-04：本层不存在任何执行面）。

/// 动作可用性（AC-02 诚实分级：灰显/引导/深链，绝不伪装成功）
public enum ActionAvailability: Equatable, Sendable {
    case available
    /// 参数为权限名（AC-04：首次使用解释并引导；拒绝则动作降级）
    case needsPermission(String)
    /// 当前系统版本/机型不支持（如未过回归验证的 macOS 大版本）
    case unavailableOnSystem
    /// 无公开 API 的开关只提供跳系统设置的深链（不伪装开关）
    case deepLinkOnly
}

/// 动作条目：面板/URL/CLI 三处寻址共用 id
public struct ButlerAction: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbolName: String
    public var availability: ActionAvailability

    public init(id: String, title: String, symbolName: String, availability: ActionAvailability) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.availability = availability
    }
}

/// 执行结果：performed 只会由注入的执行器产出；引擎与解析层自身只能给出 rejected / forwardedToApp
public enum ActionOutcome: Equatable, Sendable {
    case performed
    case rejected(reason: String)
    case forwardedToApp(actionID: String)
}

/// 动作执行器：主 App 在组合根注入。可用性/权限/降级策略全在执行器内裁决，
/// 引擎永不自带实现——"无任意执行面"（AU-04）靠这一层组织边界保证
public typealias ActionExecutor = @Sendable (_ action: ButlerAction, _ command: ButlerCommand) -> ActionOutcome

/// 内置动作真值表。availability 按规格如实静态标注，运行时权限态（已授权/已装 Helper）由执行器复核；
/// 面板可见性与排序是设置层的事（AC-01），不在此表
public struct ActionRegistry {
    public static let builtin: [ButlerAction] = [
        // AC-02 首批：公开通道直控
        ButlerAction(id: "volume", title: "音量", symbolName: "speaker.wave.2.fill", availability: .available),
        ButlerAction(id: "mute", title: "静音", symbolName: "speaker.slash.fill", availability: .available),
        ButlerAction(id: "wifi-toggle", title: "Wi-Fi 开关", symbolName: "wifi", availability: .available),
        ButlerAction(id: "bluetooth-toggle", title: "蓝牙开关", symbolName: "bluetooth", availability: .available),
        ButlerAction(id: "bluetooth-connect", title: "连接蓝牙设备", symbolName: "headphones", availability: .available),
        ButlerAction(id: "screen-off", title: "熄屏", symbolName: "moon.zzz", availability: .available),
        ButlerAction(id: "panel", title: "打开面板", symbolName: "square.grid.2x2", availability: .available),
        ButlerAction(id: "slot-cycle", title: "槽位轮换", symbolName: "arrow.2.squarepath", availability: .available),
        ButlerAction(id: "speedtest", title: "网络测速", symbolName: "speedometer", availability: .available),
        ButlerAction(id: "healthcheck", title: "健康体检", symbolName: "stethoscope", availability: .available),
        ButlerAction(id: "theme", title: "应用主题", symbolName: "paintbrush", availability: .available),
        // 只读查询项（AU-03 status --json 的同源动作；面板默认不露出）
        ButlerAction(id: "status", title: "状态查询", symbolName: "doc.text.magnifyingglass", availability: .available),
        // 诚实分级：需要授权 / 只能深链
        ButlerAction(id: "darkmode", title: "深浅外观切换", symbolName: "circle.lefthalf.filled", availability: .needsPermission("辅助功能")),
        ButlerAction(id: "fan-max", title: "风扇全速应急", symbolName: "wind", availability: .needsPermission("特权 Helper")),
        ButlerAction(id: "dnd", title: "勿扰模式", symbolName: "moon.fill", availability: .deepLinkOnly),
    ]

    public static func action(id: String) -> ButlerAction? {
        builtin.first { $0.id == id }
    }

    private init() {}
}

/// 动作中心引擎：命令 → 白名单解析 → 注册表路由 → 注入的执行器。
/// 自身不碰系统、不起进程；拒绝一律静默返回（AU-01：无报错弹窗，日志由调用方记）
public struct ActionCenter: Sendable {
    public let executor: ActionExecutor

    public init(executor: @escaping ActionExecutor) {
        self.executor = executor
    }

    /// URL 事件总入口（挂主 App 的 onOpenURL / application(_:open:)）。
    /// 返回 nil = 非 butler:// scheme，交还系统处理
    public func perform(url: URL) -> ActionOutcome? {
        guard let parsed = ButlerCommand.parse(url) else { return nil }
        switch parsed {
        case .success(let command):
            return perform(command)
        case .failure(let error):
            return .rejected(reason: error.summary)
        }
    }

    /// 已解析命令入口（CLI 转发与 AppIntents 复用）
    public func perform(_ command: ButlerCommand) -> ActionOutcome {
        switch ButlerCommand.resolve(command) {
        case .forwardedToApp(let actionID):
            guard let action = ActionRegistry.action(id: actionID) else {
                return .rejected(reason: "动作未注册：\(actionID)")
            }
            return executor(action, command)
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .performed:
            return .performed  // resolve 不会产出此分支；穷举防御
        }
    }
}
