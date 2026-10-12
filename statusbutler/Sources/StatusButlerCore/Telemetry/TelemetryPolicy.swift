import Foundation

// T-055a：遥测策略纯函数 + installID 持久化。判定与持久化分离——
// 判定必须可全组合枚举测试（consent × debug × 网络三轴），不掺环境读取。

/// 策略命名空间：发送资格 / 24h 节流 / 安装 ID 持久化键，全部可注入、可测试
public enum TelemetryPolicy {
    /// OG-FR-201 心跳节流：24 小时一条，再少无意义（版本分布统计的最小采样粒度）
    public static let heartbeatInterval: TimeInterval = 24 * 60 * 60

    // MARK: - UserDefaults 键（唯一登记处）

    public static let installationIDKey = "telemetry.installationID"
    public static let consentKey = "telemetry.consent"
    public static let lastSentAtKey = "telemetry.lastHeartbeatSentAt"

    // MARK: - 发送资格

    /// 发送资格 = 三条件全满足，缺一即静默不发：
    /// - consent == .optedIn：默认关的唯一例外通道（notAsked/optedOut 一律不发）
    /// - !isDebugBuild：生产与调试构建资格分离（S11）——开发机流量不得混入生产统计，
    ///   本地验证遥测链路走单测假传输（TelemetryTests 的桩 session）
    /// - networkReachable：离线不攒队列，恢复后下一个 tick 自然补发（24h 粒度无所谓迟到）
    public static func shouldSend(
        consent: TelemetryConsent,
        isDebugBuild: Bool,
        networkReachable: Bool
    ) -> Bool {
        consent == .optedIn && !isDebugBuild && networkReachable
    }

    // MARK: - 24h 节流

    /// 到期 = 距上次发送满 interval（含整点）；从未发送（nil）视为到期。
    /// 满 24h 整点即发的口径与 WeatherCache.isFresh 的"满 TTL 即过期"对称，边界只有一侧歧义
    public static func isDue(
        lastSentAt: Date?,
        now: Date,
        interval: TimeInterval = heartbeatInterval
    ) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= interval
    }

    // MARK: - 安装 ID

    /// 稳定随机安装 ID：首读生成 UUID 落盘，此后每次读同一值（OG-FR-201"随机安装 ID"）。
    /// 脏值（手改/损坏）按首读处理重新生成——ID 只用于聚合去重，不承载任何身份含义。
    /// defaults 注入用于测试隔离，不碰 .standard
    public static func installationID(defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: installationIDKey), let existing = UUID(uuidString: raw) {
            return existing
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: installationIDKey)
        return fresh
    }
}
