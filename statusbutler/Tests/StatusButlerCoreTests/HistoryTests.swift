import Foundation
import Testing
@testable import StatusButlerCore

// T-043: 历史库三表 —— 建表/插入/upsert/prune/事件过滤 + CSV 转义（内存库零落盘）
@Suite struct HistoryTests {
    private let oldDate = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01T00:00:00Z

    @Test func inMemorySchemaAndRoundtrip() throws {
        let db = try HistoryDatabase(url: nil)
        try db.recordMetricDaily(date: "2026-10-12", batteryCapacityPercent: 92, cycleCount: 120)
        try db.recordTrafficHourly(hour: "2026-10-12T10:00", bytesIn: 100, bytesOut: 50)
        #expect(try db.listMetricDaily() == [DailyMetric(date: "2026-10-12", batteryCapacityPercent: 92, cycleCount: 120)])
        #expect(try db.listTrafficHourly() == [HourlyTraffic(hour: "2026-10-12T10:00", bytesIn: 100, bytesOut: 50)])
    }

    @Test func metricDailyUpsertsSameDate() throws {
        let db = try HistoryDatabase(url: nil)
        try db.recordMetricDaily(date: "2026-10-12", batteryCapacityPercent: 90, cycleCount: 100)
        try db.recordMetricDaily(date: "2026-10-12", batteryCapacityPercent: 91, cycleCount: 101)
        let rows = try db.listMetricDaily()
        #expect(rows.count == 1)
        #expect(rows.first?.batteryCapacityPercent == 91)
        #expect(rows.first?.cycleCount == 101)
    }

    @Test func trafficHourlyAccumulates() throws {
        let db = try HistoryDatabase(url: nil)
        try db.recordTrafficHourly(hour: "2026-10-12T10:00", bytesIn: 100, bytesOut: 40)
        try db.recordTrafficHourly(hour: "2026-10-12T10:00", bytesIn: 10, bytesOut: 5)
        try db.recordTrafficHourly(hour: "2026-10-12T11:00", bytesIn: 1, bytesOut: 1)
        #expect(try db.listTrafficHourly() == [
            HourlyTraffic(hour: "2026-10-12T10:00", bytesIn: 110, bytesOut: 45),
            HourlyTraffic(hour: "2026-10-12T11:00", bytesIn: 1, bytesOut: 1),
        ])
    }

    @Test func eventListFiltersByKindAndSince() throws {
        let db = try HistoryDatabase(url: nil)
        try db.recordEvent(at: Date(timeIntervalSince1970: 1_756_681_600), kind: "wifiDisconnect", detail: "断开")  // 2025-09-01
        try db.recordEvent(at: Date(timeIntervalSince1970: 1_760_070_400), kind: "chargeStart", detail: "接入电源")   // 2025-10-11
        try db.recordEvent(at: Date(timeIntervalSince1970: 1_760_156_800), kind: "wifiDisconnect", detail: nil)        // 2025-10-12
        #expect(try db.listEvents().count == 3)
        #expect(try db.listEvents(kind: "wifiDisconnect").count == 2)
        #expect(try db.listEvents(kind: "chargeStart").first?.detail == "接入电源")
        #expect(try db.listEvents(since: Date(timeIntervalSince1970: 1_759_334_400)).count == 2)   // 2025-10-01 起
        #expect(try db.listEvents(since: Date(timeIntervalSince1970: 1_759_334_400), kind: "wifiDisconnect").count == 1)
    }

    @Test func pruneRemovesOnlyExpiredRows() throws {
        let db = try HistoryDatabase(url: nil)
        try db.recordEvent(at: oldDate, kind: "alert", detail: nil)
        try db.recordEvent(at: Date(), kind: "alert", detail: nil)
        try db.recordMetricDaily(date: "2020-01-01", batteryCapacityPercent: 80, cycleCount: 1)
        try db.recordMetricDaily(date: HistoryDatabase.dayKey(Date()), batteryCapacityPercent: 90, cycleCount: 2)
        try db.recordTrafficHourly(hour: "2020-01-01T00:00", bytesIn: 1, bytesOut: 1)
        try db.recordTrafficHourly(hour: HistoryDatabase.hourKey(Date()), bytesIn: 2, bytesOut: 2)
        let removed = try db.prune(olderThan: 30)
        #expect(removed == 3)
        #expect(try db.listEvents().count == 1)
        #expect(try db.listMetricDaily().count == 1)
        #expect(try db.listTrafficHourly().count == 1)
    }

    @Test func retentionPolicyAppliesSpecCutoffs() throws {
        // HS-02：事件 30 天 / 电池健康 365 天 / 流量 90 天 —— 100 天前的行应只清理事件与流量
        let db = try HistoryDatabase(url: nil)
        let now = Date()
        let ancient = now.addingTimeInterval(-100 * 86400)
        try db.recordEvent(at: ancient, kind: "alert", detail: nil)
        try db.recordMetricDaily(date: HistoryDatabase.dayKey(ancient), batteryCapacityPercent: 85, cycleCount: 3)
        try db.recordTrafficHourly(hour: HistoryDatabase.hourKey(ancient), bytesIn: 1, bytesOut: 1)
        let counts = try db.applyRetentionPolicy(now: now)
        #expect(counts.events == 1)
        #expect(counts.metrics == 0)
        #expect(counts.traffic == 1)
    }

    @Test func fileBackedDatabaseReopens() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let db = try HistoryDatabase(url: url)
            try db.recordEvent(at: Date(timeIntervalSince1970: 1_769_000_000), kind: "chargeStop", detail: "拔掉电源")
        }
        let reopened = try HistoryDatabase(url: url)
        let events = try reopened.listEvents()
        #expect(events.count == 1)
        #expect(events.first?.kind == "chargeStop")
        #expect(events.first?.detail == "拔掉电源")
    }

    @Test func csvEscapesCommasQuotesAndNewlines() {
        let rows = [
            HistoryEvent(id: 1, at: "2026-10-12T00:00:00Z", kind: "wifiDisconnect", detail: "AP-1, 5G"),
            HistoryEvent(id: 2, at: "2026-10-12T01:00:00Z", kind: "quote", detail: "say \"hi\""),
            HistoryEvent(id: 3, at: "2026-10-12T02:00:00Z", kind: "multiline", detail: "line1\nline2"),
            HistoryEvent(id: 4, at: "2026-10-12T03:00:00Z", kind: "plain", detail: nil),
        ]
        let csv = HistoryCSV.eventsToCSV(rows)
        #expect(csv.hasPrefix("id,at,kind,detail\n"))
        #expect(csv.contains("\"AP-1, 5G\""))
        #expect(csv.contains("\"say \"\"hi\"\"\""))
        #expect(csv.contains("\"line1\nline2\""))
        // 无特殊字符字段不加引号，nil detail 输出空字段
        #expect(csv.contains("4,2026-10-12T03:00:00Z,plain,"))
    }

    @Test func csvEmptyInputIsHeaderOnly() {
        #expect(HistoryCSV.eventsToCSV([]) == "id,at,kind,detail")
    }
}
