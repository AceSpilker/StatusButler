import Foundation

// T-216 Shortcuts 钉选（E2·AC-03：把用户已有的 macOS 快捷指令钉进动作面板）。
// macOS 无公开 API 枚举系统快捷指令（Shortcuts 没有 AppleScript/URL 查询面，
// 数据库在各自 App 沙盒里）——诚实降级：浏览跳 Shortcuts App 本体（shortcuts://），
// 钉选名单由用户在设置侧手工登记后经 provider 注入，本层不虚构系统枚举结果。

// MARK: - 钉选项

/// 钉进面板的一条快捷指令（id 稳定可做 ForEach 键；执行深链按 name 构造——
/// Shortcuts 的 run-shortcut 只认名字）
public struct ShortcutPin: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 钉选名单 provider：真实现读设置侧登记的名单（占位——macOS 无公开枚举 API，
/// 见文件头）；nil/空名单即钉选区隐藏
public typealias ShortcutsListProvider = @Sendable () -> [ShortcutPin]

// MARK: - 深链（纯函数）

public enum ShortcutLink {
    /// 打开 Shortcuts App（"Shortcuts…"按钮与浏览入口）
    public static let appURL = URL(string: "shortcuts://")!

    /// 执行深链：Apple 文档化 scheme `shortcuts://run-shortcut?name=<名字>`。
    /// 名字经 URLComponents 百分号编码（中文/空格快捷指令名合法且常见）；
    /// 返回 URL?——非法名字（控制字符等）构造失败时调用方放弃，不猜
    public static func runURL(name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }
}
