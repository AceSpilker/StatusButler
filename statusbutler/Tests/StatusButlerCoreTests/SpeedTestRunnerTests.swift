import Foundation
import Testing
@testable import StatusButlerCore

// T-217 测试：networkQuality JSON 解析（真实输出形态 fixture/流式形态/坏行跳过/
// 缺字段降级/单位换算边界）、两态进度（注入收集器零系统依赖）、协议便捷入口、
// 历史缓存容量裁剪。fixture 字段形状取自 2026-10 真机 `networkQuality -v -c` 输出。

@Suite struct SpeedTestRunnerTests {

    // MARK: - fixture

    /// 数值选换算后为整数的（125000000 B/s = 1000 Mbps），断言可走精确等值
    private static let summaryJSON = """
    {
      "base_rtt" : 148.5,
      "dl_throughput" : 125000000,
      "ul_throughput" : 62500000,
      "il_h2_req_resp" : [
        100,
        110,
        105
      ],
      "interface_name" : "en0"
    }
    """

    // MARK: - 解析

    @Test func summaryFixtureParsesAllFields() throws {
        let result = try #require(NetworkQualityRunner.parse(stdout: Self.summaryJSON))
        #expect(result.downloadMbps == 1000)
        #expect(result.uploadMbps == 500)
        #expect(result.latencyMs == 148.5)
        // 抖动 = 相邻样本平均绝对差 (10+5)/2 = 7.5
        #expect(result.jitterMs == 7.5)
    }

    @Test func realWorldPrettyJSONShapeParses() throws {
        // 真机输出的最小复刻：多行美化 + 无关键夹杂 + lud 数组兜底（il 缺席时）
        let stdout = """
        ==== CONFIG ====
        {
            "dl_flows" : 13,
            "dl_throughput" : 811130816,
            "lud_foreign_h2_req_resp" : [
                75,
                67,
                74,
                68
            ],
            "ul_throughput" : 114741192
        }
        """
        let result = try #require(NetworkQualityRunner.parse(stdout: stdout))
        #expect(result.downloadMbps == 811130816.0 * 8 / 1e6)
        #expect(result.uploadMbps == 114741192.0 * 8 / 1e6)
        // il 数组缺席 → lud 兜底：抖动 = (8+7+6)/3
        #expect(result.jitterMs == 21.0 / 3.0)
        #expect(result.latencyMs == nil, "未含 base_rtt 时按未测得处理，不造数")
    }

    @Test func progressStreamTakesLastSummaryObject() throws {
        // 流式形态（防未来系统改回逐行输出）：progress-only 对象无吞吐字段，天然出局
        let stdout = """
        {"progress": 0.2}
        {"progress": 0.8}
        {"dl_throughput": 125000000, "ul_throughput": 62500000, "base_rtt": 20.0}
        """
        let result = try #require(NetworkQualityRunner.parse(stdout: stdout))
        #expect(result.downloadMbps == 1000)
        #expect(result.uploadMbps == 500)
        #expect(result.latencyMs == 20.0)
    }

    @Test func garbageLinesAndBadObjectsAreSkipped() throws {
        // 坏对象（截断/不完整键）夹在好对象之间：逐个跳过，好对象仍被取出
        let stdout = """
        START LOG
        {"note": "a } brace inside string", "dl_throughput": 125000000, "ul_throughput": 62500000}
        {"broken": 
        TRAILING NOISE
        """
        let result = try #require(NetworkQualityRunner.parse(stdout: stdout))
        // 字符串内花括号不得截断对象（扫描须感知字符串/转义）
        #expect(result.downloadMbps == 1000)
        #expect(result.uploadMbps == 500)
    }

    @Test func missingFieldsDegradeToNilNotZero() throws {
        let result = try #require(
            NetworkQualityRunner.parse(stdout: #"{"dl_throughput": 125000000}"#)
        )
        #expect(result.downloadMbps == 1000)
        #expect(result.uploadMbps == nil, "缺字段 = 未测得，绝不用 0 冒充")
        #expect(result.latencyMs == nil)
        #expect(result.jitterMs == nil)
    }

    @Test func junkInputYieldsNil() {
        #expect(NetworkQualityRunner.parse(stdout: "") == nil)
        #expect(NetworkQualityRunner.parse(stdout: "not json at all") == nil)
        // 未闭合的对象：扫描器凑不出一对括号
        #expect(NetworkQualityRunner.parse(stdout: #"{"dl_throughput": 1000"#) == nil)
        // 只有 progress 流、没有 summary：无吞吐字段可取
        #expect(
            NetworkQualityRunner.parse(stdout: "{\"progress\": 0.5}\n{\"progress\": 1.0}") == nil
        )
    }

    @Test func unitConversionAndValueHygieneEdges() {
        // 1 B/s → 8e-6 Mbps（同一算术路径精确比对）
        let tiny = NetworkQualityRunner.parse(stdout: #"{"dl_throughput": 1}"#)
        #expect(tiny?.downloadMbps == 1 * 8 / 1e6)
        // 负吞吐判无效：唯一吞吐字段无效 → 整体 nil
        #expect(NetworkQualityRunner.parse(stdout: #"{"dl_throughput": -5}"#) == nil)
        // 布尔在 JSONSerialization 里也是 NSNumber：必须按 CF 类型拒收
        let mixed = NetworkQualityRunner.parse(
            stdout: #"{"dl_throughput": true, "ul_throughput": 25000000}"#
        )
        #expect(mixed?.downloadMbps == nil)
        #expect(mixed?.uploadMbps == 200)
        // 字符串数字不越权换算
        let stringy = NetworkQualityRunner.parse(
            stdout: #"{"dl_throughput": "125000000"}"#
        )
        #expect(stringy == nil)
    }

    @Test func jitterMathKnownAndInsufficientSamples() {
        #expect(NetworkQualityRunner.jitterMs(samples: [100, 110, 105]) == 7.5)
        #expect(NetworkQualityRunner.jitterMs(samples: [50, 50]) == 0)
        #expect(NetworkQualityRunner.jitterMs(samples: [42]) == nil)
        #expect(NetworkQualityRunner.jitterMs(samples: []) == nil)
    }

    // MARK: - 运行器（注入收集器，零系统依赖）

    @Test func twoStateProgressWithInjectedCollector() async throws {
        let progress = ProgressRecorder()
        let runner = NetworkQualityRunner(collect: { Self.summaryJSON })
        let result = await runner.run(onProgress: { progress.append($0) })
        // 本机实测无中间进度行：两态即全部事实
        #expect(progress.values == [0, 1])
        #expect(try #require(result).downloadMbps == 1000)
    }

    @Test func failedCollectorYieldsNilButStillSignalsProgress() async {
        let progress = ProgressRecorder()
        let runner = NetworkQualityRunner(collect: { nil })
        let result = await runner.run(onProgress: { progress.append($0) })
        #expect(result == nil)
        #expect(progress.values == [0, 1], "失败路径也要收口进度，UI 不悬停")
    }

    @Test func runConvenienceWithoutProgress() async throws {
        let runner = NetworkQualityRunner(collect: { Self.summaryJSON })
        let result = await runner.run()
        #expect(try #require(result).uploadMbps == 500)
    }
}

// MARK: - 历史缓存（E10 弹层最近 5 次）

@Suite @MainActor struct SpeedTestHistoryTests {

    private func result(_ id: Double) -> SpeedTestResult {
        SpeedTestResult(
            downloadMbps: id, uploadMbps: id, latencyMs: id, jitterMs: id,
            timestamp: Date(timeIntervalSince1970: id)
        )
    }

    @Test func recordClampsToCapacityFive() {
        let history = SpeedTestHistory()
        for id in stride(from: 1.0, through: 7.0, by: 1.0) { history.record(result(id)) }
        #expect(history.recent.count == SpeedTestHistory.capacity)
        #expect(history.mostRecent?.downloadMbps == 7)
        // 裁掉的是最旧的：首条应为 3
        #expect(history.recent.first?.downloadMbps == 3)
    }

    @Test func prefillClampsToLatestTail() {
        let history = SpeedTestHistory(
            recent: Array(stride(from: 1.0, through: 8.0, by: 1.0)).map(result)
        )
        #expect(history.recent.count == SpeedTestHistory.capacity)
        #expect(history.recent.first?.downloadMbps == 4, "预置同样留最新尾部")
        #expect(history.mostRecent?.downloadMbps == 8)
    }

    @Test func emptyHistoryHasNoMostRecent() {
        #expect(SpeedTestHistory().mostRecent == nil)
        #expect(SpeedTestHistory().recent.isEmpty)
    }
}

// MARK: - 测试基建

/// 线程安全进度记录器（onProgress 闭包 @Sendable）
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func append(_ value: Double) { lock.withLock { items.append(value) } }
    var values: [Double] { lock.withLock { items } }
}
