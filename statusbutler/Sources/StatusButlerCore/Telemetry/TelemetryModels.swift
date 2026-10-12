import Foundation

// T-055a（A2·S11·OG-FR-201 匿名遥测）：最小心跳载荷 + 三态同意模型。
// 纪律：遥测默认关（optedIn 才发）、字段集合即全部 payload（禁止扩字段）。

/// 同意三态：未询问 / 明确加入 / 明确退出。
/// 默认值是 notAsked（而非 optedIn）——"默认关"的落盘点，写入 UserDefaults 时缺键即本态
public enum TelemetryConsent: String, Codable, Equatable, Sendable, CaseIterable {
    case notAsked
    case optedIn
    case optedOut
}

/// OG-FR-201 心跳载荷：随机安装 ID + App/macOS 版本 + 语言 + 图标位置 + 发送时刻。
/// 红线（S11 最小化）：本结构体的字段集合就是全部 payload——禁止扩字段。
/// 加字段 = 隐私文档公示范围变更 = 需要用户重新知情的 产品决策，不是工程便利；
/// 该集合由 TelemetryTests.heartbeatCodableKeySetIsPinned 钉死（Codable 键集逐键断言）。
/// 不含：姓名/账号/网络信息/硬件序列号/任何设备指纹（S11 明令排除项）
public struct TelemetryHeartbeat: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let appVersion: String
    public let osVersion: String
    public let language: String
    /// AppIconPlacement.rawValue（menuBarOnly/dockOnly/both）——存字符串而非枚举，
    /// 载荷不随本地枚举演化膨胀，服务端只做分组统计
    public let iconPlacement: String
    public let sentAt: Date

    /// 显式钉键：防止未来重构把属性重命名悄悄漂移进 payload（键集测试同步失败）
    enum CodingKeys: String, CodingKey {
        case installationID
        case appVersion
        case osVersion
        case language
        case iconPlacement
        case sentAt
    }

    /// 纯函数生成器：所有输入显式传入（含 sentAt），无环境读取、无时钟读取——
    /// 环境快照（Bundle/ProcessInfo/Locale）由 readEnvironment 在调用侧单独收敛
    public static func make(
        installationID: UUID,
        appVersion: String,
        osVersion: String,
        language: String,
        iconPlacement: AppIconPlacement,
        sentAt: Date
    ) -> TelemetryHeartbeat {
        TelemetryHeartbeat(
            installationID: installationID,
            appVersion: appVersion,
            osVersion: osVersion,
            language: language,
            iconPlacement: iconPlacement.rawValue,
            sentAt: sentAt
        )
    }

    /// 环境读取点：版本/系统/语言的系统 API 全部收敛在这一个函数，
    /// 便于审计（S11 要求"隐私文档公开全字段"——字段来源必须有唯一可查出处）。
    /// installationID 与 iconPlacement 仍由调用方注入：前者来自 TelemetryPolicy 持久化，
    /// 后者是运行时可变的用户设置
    public static func readEnvironment(
        installationID: UUID,
        placement: AppIconPlacement,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        locale: Locale = .current,
        sentAt: Date = Date()
    ) -> TelemetryHeartbeat {
        let version = processInfo.operatingSystemVersion
        return make(
            installationID: installationID,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            language: locale.identifier,
            iconPlacement: placement,
            sentAt: sentAt
        )
    }
}
