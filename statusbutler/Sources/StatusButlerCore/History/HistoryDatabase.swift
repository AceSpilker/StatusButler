import Foundation
import SQLite3

// E10·HS-01/02 状态历史存储：系统 SQLite3 直连（Apple 平台随 SDK 提供，零第三方依赖）。
// 纯本地落盘（HS-05 不进遥测、不同步 iCloud）；库文件路径由调用方注入，nil = 内存库（测试零落盘）。
// 建议集成路径：~/Library/Application Support/StatusButler/history.sqlite（调用方负责建目录）。

// SQLITE_TRANSIENT：让 SQLite 在 bind 时立即复制字符串 —— Swift String 转 C 指针仅在调用期间有效，用 SQLITE_STATIC 会读到悬垂内存
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct HistoryEvent: Sendable, Equatable {
    public let id: Int64
    public let at: String        // ISO-8601 UTC（定宽格式，字典序 == 时间序，SQL 直接字符串比较）
    public let kind: String      // HS-01 事件分类：wifiDisconnect / chargeStart / bluetoothConnect / fanModeChange / alert ...
    public let detail: String?

    public init(id: Int64, at: String, kind: String, detail: String?) {
        self.id = id
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

public struct DailyMetric: Sendable, Equatable {
    public let date: String      // yyyy-MM-dd
    public let batteryCapacityPercent: Int
    public let cycleCount: Int

    public init(date: String, batteryCapacityPercent: Int, cycleCount: Int) {
        self.date = date
        self.batteryCapacityPercent = batteryCapacityPercent
        self.cycleCount = cycleCount
    }
}

public struct HourlyTraffic: Sendable, Equatable {
    public let hour: String      // yyyy-MM-dd'T'HH:00
    public let bytesIn: Int
    public let bytesOut: Int

    public init(hour: String, bytesIn: Int, bytesOut: Int) {
        self.hour = hour
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

// @unchecked Sendable 论证：sqlite3 句柄不逃逸出本类，全部访问经 lock 串行化；
// 编译器无法静态核对裸指针的互斥纪律，只能以纪律保证 —— 新增方法必须整体包进 withLock
public final class HistoryDatabase: @unchecked Sendable {
    public enum HistoryError: Error, Equatable {
        case openFailed(String)
        case sqlFailed(String)
    }

    private let db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL?) throws {
        // FULLMUTEX 让连接自身线程安全；类内 lock 再保证"prepare→bind→step→finalize"整段串行，双保险防跨方法交错
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close_v2(handle)
            throw HistoryError.openFailed(message)
        }
        do {
            try Self.exec(on: opened, """
                CREATE TABLE IF NOT EXISTS metric_daily(
                    date                    TEXT PRIMARY KEY,
                    batteryCapacityPercent  INTEGER NOT NULL,
                    cycleCount              INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS event_log(
                    id      INTEGER PRIMARY KEY AUTOINCREMENT,
                    at      TEXT NOT NULL,
                    kind    TEXT NOT NULL,
                    detail  TEXT
                );
                CREATE TABLE IF NOT EXISTS traffic_hourly(
                    hour     TEXT PRIMARY KEY,
                    bytesIn  INTEGER NOT NULL,
                    bytesOut INTEGER NOT NULL
                );
                """)
        } catch {
            sqlite3_close_v2(opened)  // 建表失败必须收回句柄，否则泄漏
            throw error
        }
        db = opened
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: 键格式
    // ISO-8601 定宽 UTC → 字符串比较即时间比较；formatter 每次新建而非静态缓存：DateFormatter 系非线程安全，静态缓存会引入全局共享可变状态

    public static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func dayKey(_ date: Date) -> String {
        String(isoTimestamp(date).prefix(10))
    }

    public static func hourKey(_ date: Date) -> String {
        String(isoTimestamp(date).prefix(13)) + ":00"
    }

    // MARK: 写入

    /// 每日一条（HS-01）；同日重采样以最新为准，故 REPLACE 覆盖。
    public func recordMetricDaily(date: String, batteryCapacityPercent: Int, cycleCount: Int) throws {
        try lock.withLock {
            try Self.step(db, """
                INSERT OR REPLACE INTO metric_daily(date, batteryCapacityPercent, cycleCount)
                VALUES (?1, ?2, ?3)
                """) { stmt in
                sqlite3_bind_text(stmt, 1, date, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(batteryCapacityPercent))
                sqlite3_bind_int64(stmt, 3, Int64(cycleCount))
            }
        }
    }

    public func recordEvent(at date: Date = Date(), kind: String, detail: String? = nil) throws {
        try lock.withLock {
            try Self.step(db, "INSERT INTO event_log(at, kind, detail) VALUES (?1, ?2, ?3)") { stmt in
                sqlite3_bind_text(stmt, 1, Self.isoTimestamp(date), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
                Self.bindOptionalText(stmt, 3, detail)
            }
        }
    }

    /// 小时桶"累加"upsert：监控器 30s 粗采样会在同一小时内多次推送（HS-01），覆盖语义会丢流量。
    public func recordTrafficHourly(hour: String, bytesIn: Int, bytesOut: Int) throws {
        try lock.withLock {
            try Self.step(db, """
                INSERT INTO traffic_hourly(hour, bytesIn, bytesOut) VALUES (?1, ?2, ?3)
                ON CONFLICT(hour) DO UPDATE SET
                    bytesIn  = bytesIn  + excluded.bytesIn,
                    bytesOut = bytesOut + excluded.bytesOut
                """) { stmt in
                sqlite3_bind_text(stmt, 1, hour, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(bytesIn))
                sqlite3_bind_int64(stmt, 3, Int64(bytesOut))
            }
        }
    }

    // MARK: 查询

    public func listEvents(since: Date? = nil, kind: String? = nil) throws -> [HistoryEvent] {
        try lock.withLock {
            try Self.query(db, """
                SELECT id, at, kind, detail FROM event_log
                WHERE (?1 IS NULL OR at >= ?1) AND (?2 IS NULL OR kind = ?2)
                ORDER BY at, id
                """) { stmt in
                if let since {
                    sqlite3_bind_text(stmt, 1, Self.isoTimestamp(since), -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
                if let kind {
                    sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
            } read: { stmt in
                HistoryEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    at: String(cString: sqlite3_column_text(stmt, 1)),
                    kind: String(cString: sqlite3_column_text(stmt, 2)),
                    detail: sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                )
            }
        }
    }

    public func listMetricDaily() throws -> [DailyMetric] {
        try lock.withLock {
            try Self.query(db, "SELECT date, batteryCapacityPercent, cycleCount FROM metric_daily ORDER BY date", bind: { _ in }) { stmt in
                DailyMetric(
                    date: String(cString: sqlite3_column_text(stmt, 0)),
                    batteryCapacityPercent: Int(sqlite3_column_int64(stmt, 1)),
                    cycleCount: Int(sqlite3_column_int64(stmt, 2))
                )
            }
        }
    }

    public func listTrafficHourly(since: Date? = nil) throws -> [HourlyTraffic] {
        try lock.withLock {
            try Self.query(db, """
                SELECT hour, bytesIn, bytesOut FROM traffic_hourly
                WHERE (?1 IS NULL OR hour >= ?1)
                ORDER BY hour
                """) { stmt in
                if let since {
                    sqlite3_bind_text(stmt, 1, Self.hourKey(since), -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
            } read: { stmt in
                HourlyTraffic(
                    hour: String(cString: sqlite3_column_text(stmt, 0)),
                    bytesIn: Int(sqlite3_column_int64(stmt, 1)),
                    bytesOut: Int(sqlite3_column_int64(stmt, 2))
                )
            }
        }
    }

    // MARK: 清理

    /// 三表按同一 cutoff 分别清理（保留策略的通用原语），返回删除总行数。
    @discardableResult
    public func prune(olderThan days: Int, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86400)
        return try lock.withLock {
            try Self.step(db, "DELETE FROM event_log WHERE at < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.isoTimestamp(cutoff), -1, SQLITE_TRANSIENT)
            }
            let events = sqlite3_changes(db)
            try Self.step(db, "DELETE FROM metric_daily WHERE date < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.dayKey(cutoff), -1, SQLITE_TRANSIENT)
            }
            let metrics = sqlite3_changes(db)
            try Self.step(db, "DELETE FROM traffic_hourly WHERE hour < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.hourKey(cutoff), -1, SQLITE_TRANSIENT)
            }
            let traffic = sqlite3_changes(db)
            return Int(events + metrics + traffic)
        }
    }

    /// HS-02 规格保留策略：事件 30 天 / 电池健康 365 天 / 流量 90 天。
    @discardableResult
    public func applyRetentionPolicy(now: Date = Date()) throws -> (events: Int, metrics: Int, traffic: Int) {
        try lock.withLock {
            try Self.step(db, "DELETE FROM event_log WHERE at < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.isoTimestamp(now.addingTimeInterval(-30 * 86400)), -1, SQLITE_TRANSIENT)
            }
            let events = sqlite3_changes(db)
            try Self.step(db, "DELETE FROM metric_daily WHERE date < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.dayKey(now.addingTimeInterval(-365 * 86400)), -1, SQLITE_TRANSIENT)
            }
            let metrics = sqlite3_changes(db)
            try Self.step(db, "DELETE FROM traffic_hourly WHERE hour < ?1") { stmt in
                sqlite3_bind_text(stmt, 1, Self.hourKey(now.addingTimeInterval(-90 * 86400)), -1, SQLITE_TRANSIENT)
            }
            let traffic = sqlite3_changes(db)
            return (Int(events), Int(metrics), Int(traffic))
        }
    }

    // MARK: SQLite 薄封装

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func exec(on db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(message) }
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            throw HistoryError.sqlFailed(message.map { String(cString: $0) } ?? "sqlite3_exec failed")
        }
    }

    private static func step(_ db: OpaquePointer?, _ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func query<T>(_ db: OpaquePointer?, _ sql: String, bind: (OpaquePointer) -> Void, read: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(read(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw HistoryError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }
}
