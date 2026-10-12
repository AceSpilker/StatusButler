import Foundation
import Testing
@testable import StatusButlerCore

// T-054a: 小组件数据层——快照编解码/原子写读容错/节流三元组/时间线外推/陈旧标注（A6·4 数据半场）

@Suite struct WidgetDataTests {

    // @unchecked Sendable 论证：仅单条测试内单线程使用，postedNames 的可变状态不跨线程
    private final class FakeNotifier: NotifierPostable, @unchecked Sendable {
        private(set) var postedNames: [String] = []
        func post(_ name: String) { postedNames.append(name) }
    }

    // MARK: - 基建

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "widget-data-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fullSnapshot(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: date,
            battery: .battery(level: 87, charging: true),
            link: .wifi(ssid: "Home", signalBars: 3),
            volume: VolumeState(level: 60, isMuted: false),
            maxCelsius: 78.5,
            fanAverageRPM: 2450,
            netBytesPerSec: WidgetSnapshot.NetRates(in: 2048, out: 512)
        )
    }

    // MARK: - 快照编解码往返

    @Test func snapshotRoundTripsFullyPopulated() throws {
        let original = fullSnapshot()
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func snapshotRoundTripsWithAllOptionalFieldsNil() throws {
        let original = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 42))
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.battery == nil && decoded.link == nil && decoded.volume == nil)
        #expect(decoded.maxCelsius == nil && decoded.fanAverageRPM == nil && decoded.netBytesPerSec == nil)
    }

    @Test func wireFormatDecodesFromPinnedLiteralJSON() throws {
        // 跨进程契约钉死：WidgetKit 扩展（另一 target）依赖这份键名/结构，任何变化都是破坏性变更
        let json = """
        {"schemaVersion":1,"generatedAt":0,"battery":{"battery":{"level":87,"charging":true}},\
        "link":{"wifi":{"ssid":"Home","signalBars":3}},"volume":{"level":60,"isMuted":false},\
        "maxCelsius":78.5,"fanAverageRPM":2450,"netBytesPerSec":{"in":2048,"out":512}}
        """
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(decoded == fullSnapshot(at: Date(timeIntervalSinceReferenceDate: 0)))
    }

    @Test func stateCaseVariantsRoundTripThroughSnapshot() throws {
        let batteries: [BatteryState] = [.unavailable, .battery(level: 0, charging: false)]
        let links: [NetworkLink] = [
            .offline, .wired,
            .wifi(ssid: nil, signalBars: 2), .wifi(ssid: "Office", signalBars: 4),
        ]
        let volumes = [VolumeState(level: 0, isMuted: true), VolumeState(level: 100, isMuted: false)]
        for battery in batteries {
            for link in links {
                for volume in volumes {
                    let original = WidgetSnapshot(
                        generatedAt: Date(), battery: battery, link: link, volume: volume
                    )
                    let decoded = try JSONDecoder().decode(
                        WidgetSnapshot.self, from: JSONEncoder().encode(original)
                    )
                    #expect(decoded == original)
                }
            }
        }
    }

    @Test func netRatesExposesInAndOutMembers() {
        let rates = WidgetSnapshot.NetRates(in: 1024, out: 512)
        #expect(rates.in == 1024)
        #expect(rates.out == 512)
        #expect(rates == WidgetSnapshot.NetRates(in: 1024, out: 512))
    }

    // MARK: - 原子写 + 读回

    @Test func writeThenReadBackReturnsEqualSnapshot() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(directory: dir, notifier: FakeNotifier())
        try writer.write(fullSnapshot())
        #expect(writer.read() == fullSnapshot())
    }

    @Test func secondWriteOverwritesAndLeavesNoTempResidue() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(directory: dir, notifier: FakeNotifier())
        try writer.write(WidgetSnapshot(generatedAt: Date(), maxCelsius: 50))
        var second = fullSnapshot()
        second.maxCelsius = 90
        try writer.write(second)  // 第二次走 replaceItemAt 换名路径
        #expect(writer.read() == second)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path())
        #expect(contents == [WidgetSnapshotWriter.fileName])  // 目录里只有正式文件，无 .tmp 残留
    }

    @Test func writeCreatesMissingDirectories() throws {
        let base = makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let writer = WidgetSnapshotWriter(
            directory: base.appending(path: "a/b/c"), notifier: FakeNotifier()
        )
        try writer.write(WidgetSnapshot(generatedAt: Date()))
        #expect(writer.read() != nil)
    }

    // MARK: - 坏文件容错

    @Test func readReturnsNilForMissingFile() {
        let writer = WidgetSnapshotWriter(directory: makeDirectory(), notifier: FakeNotifier())
        #expect(writer.read() == nil)
    }

    @Test func readReturnsNilForCorruptJSONWithoutCrashing() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(directory: dir, notifier: FakeNotifier())
        try Data("这是坏 JSON {{{".utf8).write(to: writer.fileURL)
        #expect(writer.read() == nil)
        try Data("[1,2,3]".utf8).write(to: writer.fileURL)  // 合法 JSON 但形态不对
        #expect(writer.read() == nil)
        try Data("{\"schemaVersion\":1}".utf8).write(to: writer.fileURL)  // 缺必填字段
        #expect(writer.read() == nil)
    }

    // MARK: - 节流决策表（A6·4 三元组）

    @Test func shouldEmitFirstWriteAlwaysEmits() {
        let now = Date()
        #expect(WidgetSnapshotWriter.shouldEmit(
            previous: nil, next: WidgetSnapshot(generatedAt: now), lastEmitAt: nil, now: now
        ))
        // 有上一帧但无时间戳（调用方状态不完整）：宁可多发也不让组件冻结
        let prev = WidgetSnapshot(generatedAt: now.addingTimeInterval(-5))
        #expect(WidgetSnapshotWriter.shouldEmit(previous: prev, next: prev, lastEmitAt: nil, now: now))
    }

    @Test func shouldEmitIgnoresSmallTempDrift() {
        let now = Date()
        var prev = fullSnapshot()
        prev.maxCelsius = 50
        var next = prev
        next.maxCelsius = 50.5
        #expect(!WidgetSnapshotWriter.shouldEmit(
            previous: prev, next: next, lastEmitAt: now.addingTimeInterval(-5), now: now
        ))
    }

    @Test func shouldEmitTriggersOnTwoDegreeTempChange() {
        let now = Date()
        var prev = fullSnapshot()
        prev.maxCelsius = 50
        var up = prev
        up.maxCelsius = 52
        var down = prev
        down.maxCelsius = 48
        let recent = now.addingTimeInterval(-5)
        #expect(WidgetSnapshotWriter.shouldEmit(previous: prev, next: up, lastEmitAt: recent, now: now))
        #expect(WidgetSnapshotWriter.shouldEmit(previous: prev, next: down, lastEmitAt: recent, now: now))  // 降温同样发
    }

    @Test func shouldEmitHonorsThirtySecondInterval() {
        let now = Date()
        let prev = fullSnapshot()
        let next = prev  // 数值零变化 → 只剩间隔通道
        #expect(!WidgetSnapshotWriter.shouldEmit(
            previous: prev, next: next, lastEmitAt: now.addingTimeInterval(-29), now: now
        ))
        #expect(WidgetSnapshotWriter.shouldEmit(
            previous: prev, next: next, lastEmitAt: now.addingTimeInterval(-30), now: now
        ))  // "距上次 ≥30s" 含等号
        #expect(WidgetSnapshotWriter.shouldEmit(
            previous: prev, next: next, lastEmitAt: now.addingTimeInterval(-31), now: now
        ))
    }

    @Test func shouldEmitTriggersOnRPMChange() {
        let now = Date()
        var prev = fullSnapshot()
        prev.fanAverageRPM = 2000
        var justUnder = prev
        justUnder.fanAverageRPM = 2299
        var atThreshold = prev
        atThreshold.fanAverageRPM = 2300
        var bigDown = prev
        bigDown.fanAverageRPM = 1700
        let recent = now.addingTimeInterval(-5)
        #expect(!WidgetSnapshotWriter.shouldEmit(previous: prev, next: justUnder, lastEmitAt: recent, now: now))
        #expect(WidgetSnapshotWriter.shouldEmit(previous: prev, next: atThreshold, lastEmitAt: recent, now: now))
        #expect(WidgetSnapshotWriter.shouldEmit(previous: prev, next: bigDown, lastEmitAt: recent, now: now))
    }

    @Test func shouldEmitTreatsSensorAppearanceAsChange() {
        let now = Date()
        var prev = fullSnapshot()
        prev.maxCelsius = nil
        var next = prev
        next.maxCelsius = 45
        #expect(WidgetSnapshotWriter.shouldEmit(
            previous: prev, next: next, lastEmitAt: now.addingTimeInterval(-5), now: now
        ))
    }

    // MARK: - 时间线外推

    @Test func extrapolateConstantSeriesStaysFlat() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = fullSnapshot(at: start)
        snapshot.maxCelsius = 50
        let entries = WidgetTimeline.extrapolate(last: snapshot, recentTemps: [50, 50, 50, 50], from: start)
        #expect(entries.count == 5)
        #expect(entries.map(\.snapshot.maxCelsius).compactMap { $0 } == [50, 50, 50, 50, 50])
        #expect(entries.map(\.date) == (0..<5).map { start.addingTimeInterval(TimeInterval($0 * 300)) })
    }

    @Test func extrapolateRisingSeriesProjectsUpward() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = fullSnapshot(at: start)
        snapshot.maxCelsius = 54
        // [48,50,52,54] 最小二乘斜率恰为 2/步，锚定当前值 54
        let entries = WidgetTimeline.extrapolate(last: snapshot, recentTemps: [48, 50, 52, 54], from: start)
        #expect(entries.map(\.snapshot.maxCelsius).compactMap { $0 } == [54, 56, 58, 60, 62])
        // 其余字段原样沿用
        #expect(entries.allSatisfy {
            $0.snapshot.battery == snapshot.battery && $0.snapshot.fanAverageRPM == snapshot.fanAverageRPM
        })
    }

    @Test func extrapolateMarksStalenessProgressively() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = fullSnapshot(at: start)
        // 步进 60s、阈值 120s：各条目数据年龄 0/60/120/180/240 → [f,f,f,t,t]（120 恰等于阈值不算"超过"）
        let entries = WidgetTimeline.extrapolate(
            last: snapshot, recentTemps: [50, 51], from: start, stepSeconds: 60, count: 5
        )
        #expect(entries.map(\.isStale) == [false, false, false, true, true])
    }

    @Test func extrapolateDegenerateInputsFallBackSafely() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = fullSnapshot(at: start)
        snapshot.maxCelsius = 60
        // 样本不足 2 个 → 斜率 0，平铺当前值
        let flat = WidgetTimeline.extrapolate(last: snapshot, recentTemps: [], from: start, count: 3)
        #expect(flat.map(\.snapshot.maxCelsius).compactMap { $0 } == [60, 60, 60])
        // count 0 → 空数组
        #expect(WidgetTimeline.extrapolate(last: snapshot, recentTemps: [60, 60], from: start, count: 0).isEmpty)
        // 无当前温度 → 不外推，保持 nil
        var cold = snapshot
        cold.maxCelsius = nil
        let entries = WidgetTimeline.extrapolate(last: cold, recentTemps: [50, 52], from: start, count: 2)
        #expect(entries.allSatisfy { $0.snapshot.maxCelsius == nil })
    }

    @Test func extrapolateClampsToPhysicalWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = fullSnapshot(at: start)
        snapshot.maxCelsius = 60
        // 斜率 100/步 → 外推 160/260 被钳进 A5·TF-01 物理窗口上限 150，绝不显示假极值
        let entries = WidgetTimeline.extrapolate(last: snapshot, recentTemps: [0, 100], from: start, count: 3)
        #expect(entries.map(\.snapshot.maxCelsius).compactMap { $0 } == [60, 150, 150])
    }

    @Test func stalenessBoundaryIsStrictlyGreaterThanThreshold() {
        let generated = Date(timeIntervalSince1970: 1_000_000)
        #expect(!WidgetTimeline.staleness(generatedAt: generated, now: generated.addingTimeInterval(119.9)))
        #expect(!WidgetTimeline.staleness(generatedAt: generated, now: generated.addingTimeInterval(120)))
        #expect(WidgetTimeline.staleness(generatedAt: generated, now: generated.addingTimeInterval(120.1)))
        #expect(WidgetTimeline.staleness(generatedAt: generated, now: generated.addingTimeInterval(999)))
    }

    // MARK: - Darwin 通知（注入假实现）

    @Test func writePostsDarwinNotificationThroughInjectedNotifier() throws {
        let fake = FakeNotifier()
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(directory: dir, notifier: fake)
        try writer.write(fullSnapshot())
        #expect(fake.postedNames == [WidgetSnapshotWriter.notificationName])
        try writer.write(fullSnapshot())
        #expect(fake.postedNames.count == 2)  // 每次成功写各发一记
    }

    @Test func failedWriteDoesNotPostNotification() {
        let fake = FakeNotifier()
        // 目录路径被同名文件占住 → 建目录失败 → 抛错且绝不发"假唤醒"
        let blocker = FileManager.default.temporaryDirectory
            .appending(path: "widget-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path(), contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let writer = WidgetSnapshotWriter(directory: blocker, notifier: fake)
        var threw = false
        do { try writer.write(fullSnapshot()) } catch { threw = true }
        #expect(threw)
        #expect(fake.postedNames.isEmpty)
    }

    @Test func realDarwinNotifierPostDoesNotCrash() {
        // 冒烟：真向 Darwin 域广播一记（无监听者时无害），钉住 API 用法可编译可运行
        DarwinNotifier().post(WidgetSnapshotWriter.notificationName)
    }
}
