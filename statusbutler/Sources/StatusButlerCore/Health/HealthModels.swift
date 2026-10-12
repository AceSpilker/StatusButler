// E18·HLTH 体检模型：纯数据 + 纯函数得分（映射层保持纯函数，架构纪律）
public enum HealthStatus: String, Sendable, Equatable {
    case pass
    case warn
    case fail
    case notApplicable   // 无法判定/本机不适用：不参与计分
}

public struct HealthCheckResult: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: HealthStatus
    public let detail: String
    public let remediationHint: String   // 给用户看的一句"怎么修"；pass/notApplicable 为空串

    public init(id: String, title: String, status: HealthStatus, detail: String, remediationHint: String) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remediationHint = remediationHint
    }
}

public struct HealthReport: Sendable, Equatable {
    public let results: [HealthCheckResult]

    public init(results: [HealthCheckResult]) {
        self.results = results
    }

    // 得分 = pass 占比 × 100，notApplicable 不计分（本机不适用不应拉低分数）
    // 无可计分项（空报告/全不适用）按 100：无可检项 ≠ 不健康（HLTH-02 展示"管家体检 xx 分"）
    public var score: Int {
        let scorable = results.filter { $0.status != .notApplicable }
        guard !scorable.isEmpty else { return 100 }
        let passed = scorable.filter { $0.status == .pass }.count
        return Int((Double(passed) / Double(scorable.count) * 100).rounded())
    }
}
