import AppKit
import Foundation

// T-207 历史查看页（C2 弹层区）：读协议（UI 与 SQLite 行类型解耦）、电池健康
// 曲线坐标映射（自绘 Path 折线，macOS 13 兼容不引 Swift Charts）、事件行格式化、
// CSV 导出的 NSSavePanel 真实现（VM 经注入闭包调用，测试注入假闭包）。

// MARK: - 读协议（E10 metric_daily / event_log 的面板视图）

/// 下钻页曲线单日点（只取要画的两列；cycleCount 留给未来的明细下钻）
public struct DailyMetricPoint: Equatable, Sendable {
    /// yyyy-MM-dd（字典序 == 时间序，与库内排序一致）
    public let date: String
    public let batteryCapacityPercent: Int

    public init(date: String, batteryCapacityPercent: Int) {
        self.date = date
        self.batteryCapacityPercent = batteryCapacityPercent
    }
}

/// 事件日志行（HistoryEvent 的 UI 值类型化；id 稳定可做 ForEach 键）
public struct EventRow: Equatable, Sendable, Identifiable {
    public let id: Int64
    /// ISO-8601 UTC（落库格式原样透传，展示层再格式化）
    public let at: String
    public let kind: String
    public let detail: String?

    public init(id: Int64, at: String, kind: String, detail: String?) {
        self.id = id
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

/// 历史读取协议（注入；真实实现是同模块 retroactive 适配 HistoryDatabase，
/// 与 ThermalMonitoring 包装 ThermalMonitor 同一姿势）
public protocol HistoryReading: Sendable {
    func dailySeries() -> [DailyMetricPoint]
    func recentEvents(limit: Int) -> [EventRow]
}

/// 引擎适配：SQLite 三表 → 面板行。读取失败折叠为空（页面走空态引导，不弹错——
/// 历史是增强信息，库损坏不该打断弹层）
extension HistoryDatabase: HistoryReading {
    public func dailySeries() -> [DailyMetricPoint] {
        ((try? listMetricDaily()) ?? []).map {
            DailyMetricPoint(date: $0.date, batteryCapacityPercent: $0.batteryCapacityPercent)
        }
    }

    public func recentEvents(limit: Int) -> [EventRow] {
        // listEvents 按时间升序；"最近 limit 条"取尾部，倒序展示（新在前）归视图/VM
        ((try? listEvents()) ?? [])
            .suffix(max(limit, 0))
            .map { EventRow(id: $0.id, at: $0.at, kind: $0.kind, detail: $0.detail) }
    }
}

// MARK: - 曲线坐标映射（纯函数：数据点 → 归一化坐标）

public enum HistoryChartMapping {
    /// 容量曲线坐标：y 域固定 0...100——健康度是缓变曲线，按数据 min/max 拉伸会把
    /// ±1% 波动放大成过山车，固定域让多日趋势真可比；x 按索引均分（漏记的日期不留
    /// 空洞，340pt 宽的面板画连续趋势比精确时间轴更可读）。
    /// 单点退化为 (0, y)：画一个点而不是空图——"开始有记录"本身是信息
    public static func capacityPoints(_ series: [DailyMetricPoint], size: CGSize) -> [CGPoint] {
        guard !series.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let stepX = series.count > 1 ? size.width / Double(series.count - 1) : 0
        return series.enumerated().map { index, point in
            CGPoint(
                x: Double(index) * stepX,
                y: size.height * (1 - Double(point.batteryCapacityPercent) / 100)
            )
        }
    }

    /// 参考线 y 坐标（80% = BatteryHealthTier.attention 同门限，曲线一眼对齐"注意"线）
    public static func referenceLineY(atPercent percent: Int, height: Double) -> CGFloat? {
        guard height > 0 else { return nil }
        return height * (1 - Double(percent) / 100)
    }
}

// MARK: - 事件行格式化（纯函数）

public enum HistoryEventFormatting {
    /// kind → 展示名。落库字符串是开放集合（插件可记自定义事件），未知类型透传
    /// 原文——宁可显示英文原文也不丢行
    public static func kindDisplayName(_ kind: String) -> String {
        switch kind {
        case HistoryEventKind.wifiConnect: return "Wi-Fi 接入"
        case HistoryEventKind.wifiDisconnect: return "Wi-Fi 断开"
        case HistoryEventKind.wiredConnect: return "有线接入"
        case HistoryEventKind.wiredDisconnect: return "有线拔出"
        case HistoryEventKind.chargeStart: return "开始充电"
        case HistoryEventKind.chargeStop: return "结束充电"
        default: return kind
        }
    }

    /// kind → SF Symbol（未知类型给中性圆点）
    public static func symbolName(for kind: String) -> String {
        switch kind {
        case HistoryEventKind.wifiConnect, HistoryEventKind.wifiDisconnect: return "wifi"
        case HistoryEventKind.wiredConnect, HistoryEventKind.wiredDisconnect: return "cable.connector"
        case HistoryEventKind.chargeStart, HistoryEventKind.chargeStop: return "bolt.fill"
        default: return "circle"
        }
    }

    /// ISO-8601 → "MM-dd HH:mm"。解析失败原文透传（格式漂移不至于显示空白）；
    /// timeZone 参数默认本地（用户看本地钟点），测试注入固定时区钉死断言
    public static func timeText(iso: String, timeZone: TimeZone = .current) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        // formatter 每次新建而非静态缓存：DateFormatter 非线程安全（与 HistoryDatabase 同纪律）
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

// MARK: - CSV 导出（注入闭包的真实现）

/// VM 的导出闭包类型：建议文件名 + CSV 全文 → 是否成功落盘。
/// 默认不注入（导出按钮隐藏）；主线在组合根注入 HistoryCSVExport.presentSavePanel
public typealias HistoryExportClosure = @MainActor (_ suggestedFileName: String, _ content: String) -> Bool

public enum HistoryCSVExport {
    /// NSSavePanel 真实现（注入给 PanelViewModel）。取消保存返回 false——
    /// 用户改主意是正常路径不是错误；写盘失败同样 false（失败提示归调用方展示）
    @MainActor
    public static func presentSavePanel(suggestedFileName: String, content: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
