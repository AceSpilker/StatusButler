import Foundation

// MARK: - 系统设置深链（A14-β 下钻页的"跳系统"出口）
// 红线一的诚实行为：无公开 API 的开关/连接动作不伪装成功，一律跳系统设置让用户亲手完成。
// 本文件只收 URL 串常量与"检查项 → 面板"映射（纯函数）；打开动作经 VM 注入的 openExternal
// 走 NSWorkspace——串面被单测钉死，面板 id 随系统版本漂移时打不开的最坏结局是系统兜底开设置根
public enum PanelDeepLink {
    /// Wi-Fi 设置（附近网络行点击跳转：连接/输密码必须归系统，App 不碰密码不碰钥匙串）
    public static let wifiSettingsURLString = "x-apple.systempreferences:com.apple.Wi-Fi"
    /// 电池设置（优化充电入口；Ventura 起 pane id 为 com.apple.Battery，旧命名由系统兜底）
    public static let batterySettingsURLString = "x-apple.systempreferences:com.apple.Battery"
    /// 隐私与安全性（FileVault / Gatekeeper 检查项的修复去处）
    public static let privacySecurityURLString = "x-apple.systempreferences:com.apple.preference.security"
    /// 网络（防火墙检查项）
    public static let networkSettingsURLString = "x-apple.systempreferences:com.apple.Network"
    /// 软件更新
    public static let softwareUpdateURLString = "x-apple.systempreferences:com.apple.Software-Update"

    public static var wifiSettings: URL { URL(string: wifiSettingsURLString)! }
    public static var batterySettings: URL { URL(string: batterySettingsURLString)! }

    /// 体检检查项 id → 修复深链（HealthChecks.checkID 同源）。
    /// 未知 id 返回 nil——"去修复"按钮隐藏，比跳错面板诚实
    public static func remediationURL(forCheckID id: String) -> URL? {
        switch id {
        case "filevault", "gatekeeper":
            return URL(string: privacySecurityURLString)
        case "firewall":
            return URL(string: networkSettingsURLString)
        case "softwareUpdate":
            return URL(string: softwareUpdateURLString)
        default:
            return nil
        }
    }
}
