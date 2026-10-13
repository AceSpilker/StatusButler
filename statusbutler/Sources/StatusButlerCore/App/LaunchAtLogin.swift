import Foundation
import ServiceManagement

// 开机自启动（A2·S2 / A14 审计三·壳项）：SMAppService.mainApp 注册/注销 + 状态查询。
// 状态映射纯函数化（SMAppService.Status → UI 三态）；系统服务协议化，测试注入假实现钉行为。

/// 登录项的 UI 三态
public enum LaunchAtLoginStatus: Equatable, Sendable {
    /// 未注册（含"从未注册过"——不同 macOS 版本对该情形回报 notRegistered / notFound 其一，
    /// 两态出发的注册动作都合法，UI 上必须同形）
    case notRegistered
    case enabled
    /// 已注册但待用户在系统设置批准
    case requiresApproval

    public static func from(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }

    /// 开关口径：待批准算"开"——回显用户要求过的状态，不静默回跳成关
    public var isOn: Bool {
        self == .enabled || self == .requiresApproval
    }
}

/// 登录项系统服务：SMAppService 协议化（监控器/系统依赖全部可注入的仓库纪律同样适用）
@MainActor
public protocol LoginItemServicing: AnyObject {
    /// false = 进程不在 .app bundle 里（swift run / swift test 宿主）——macOS 无法管理其登录项
    var isSupported: Bool { get }
    var status: LaunchAtLoginStatus { get }
    func setRegistered(_ registered: Bool)
    func openSystemSettings()
}

/// 生产服务：SMAppService.mainApp（macOS 13+ 管理登录项的唯一正路，无私有 API）
@MainActor
public final class SystemLoginItemService: LoginItemServicing {
    public var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public var status: LaunchAtLoginStatus {
        LaunchAtLoginStatus.from(SMAppService.mainApp.status)
    }

    public func setRegistered(_ registered: Bool) {
        // 失败不上抛：登录项注册失败不许打断设置交互——状态回查与"待批准"提示行兜底
        if registered {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
