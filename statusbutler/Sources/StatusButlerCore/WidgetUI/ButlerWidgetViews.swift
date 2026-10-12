// T-054b 小组件视图层（A6·2）：WG-01~06 六族 SwiftUI 视图 + TimelineProvider。
// 整文件 canImport 双保护：现在编进 Core（主 App 产物带上但无副作用），
// 建 WidgetKit 扩展 target 时原样迁移零改动（T-054 收尾）。
// 视图不直测（AGENTS·验证门）：一切分支在 WidgetDisplayModels 纯函数里钉死，这里只做布局。
#if canImport(WidgetKit) && canImport(SwiftUI)
import WidgetKit
import SwiftUI

// WidgetData 的 TimelineEntry 结构体与 WidgetKit 的同名协议撞名：模块内裸名解析到我们的结构体，
// 以限定名补协议遵循（协议只要求 date）——Provider 与显示层一个类型贯穿，不造包装类型
extension TimelineEntry: WidgetKit.TimelineEntry {}

// MARK: - 公共壳

/// 空态占位（A6·2 空态设计）：对应模块未启用时给提示卡，绝不留白
private struct WidgetPlaceholderView: View {
    let hint: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("管家提示：在设置中开启\(hint)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 统一卡片壳：陈旧降透明 + "管家休息中"文案 + widgetURL 深链 + 背景适配。
/// 六族共用同一壳，桌面语系才不会一卡一貌（E1 可视化语系联动）
private struct WidgetCardShell<Content: View>: View {
    let kind: ButlerWidgetKind
    let entry: TimelineEntry
    /// 非 nil = 模块未启用空态（此时不渲染 content、不做陈旧标注——空态本身没有数据可陈旧）
    let emptyHint: String?
    let content: () -> Content

    init(
        kind: ButlerWidgetKind,
        entry: TimelineEntry,
        emptyHint: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.kind = kind
        self.entry = entry
        self.emptyHint = emptyHint
        self.content = content
    }

    var body: some View {
        // 陈旧判定用"条目自身渲染时刻 - 快照生成时刻"：外推越远的条目越旧，透明度逐条变淡（A6·4）
        let stale = StaleStyle.for(
            age: entry.date.timeIntervalSince(entry.snapshot.generatedAt),
            generatedAt: entry.snapshot.generatedAt
        )
        VStack(alignment: .leading, spacing: 6) {
            if let emptyHint {
                WidgetPlaceholderView(hint: emptyHint)
            } else {
                content()
                    .opacity(stale.opacity)
                if let resting = stale.restingText {
                    Text(resting)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackgroundCompat()
        // 空态也要能点：点击唤起主 App 是陈旧/空态共用的兜底出路（A6·3/A6·4）
        .widgetURL(URL(string: WidgetFamilyMap.descriptor(for: kind).deepLink))
    }
}

extension View {
    /// macOS 14 起组件背景必须经 containerBackground 声明（否则系统给不透明底）；
    /// macOS 13（通知中心侧栏）无该 API 退回普通背景。内容用 clear——系统材质与用户着色透出，
    /// 深浅外观自适应不写死颜色（A6·2 主题联动）
    @ViewBuilder
    func widgetBackgroundCompat() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) { Color.clear }
        } else {
            background(Color.clear)
        }
    }
}

// MARK: - WG-01 管家总览

private struct OverviewCellView: View {
    let cell: OverviewCellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: cell.symbolName)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(cell.valueText)
                .font(.headline)
                .monospacedDigit()  // 等宽数字：刷新时数字跳宽会让整卡抖动（A6·2）
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(cell.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct OverviewWidgetView: View {
    public let entry: TimelineEntry
    @Environment(\.widgetFamily) private var family

    public init(entry: TimelineEntry) {
        self.entry = entry
    }

    public var body: some View {
        WidgetCardShell(kind: .overview, entry: entry) {
            let model = OverviewCardModel.from(snapshot: entry.snapshot)
            // 各域单独降级成 "--"，四格里任何一格缺数据都不至于整卡空态
            switch family {
            case .systemMedium:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        OverviewCellView(cell: model.battery)
                        OverviewCellView(cell: model.signal)
                        OverviewCellView(cell: model.volume)
                        OverviewCellView(cell: model.temperature)
                    }
                    // M 附加行（A6 WG-01：M 加风扇 RPM）；无风扇数据不占行
                    if let fanLine = model.fanLine {
                        Text(fanLine)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                // WidgetFamily 跨平台枚举不穷举：其余一律按小尺寸四格 2×2 兜底
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        OverviewCellView(cell: model.battery)
                        OverviewCellView(cell: model.signal)
                    }
                    HStack(spacing: 6) {
                        OverviewCellView(cell: model.volume)
                        OverviewCellView(cell: model.temperature)
                    }
                }
            }
        }
    }
}

// MARK: - WG-02 温度

public struct ThermalWidgetView: View {
    public let entry: TimelineEntry

    public init(entry: TimelineEntry) {
        self.entry = entry
    }

    public var body: some View {
        WidgetCardShell(
            kind: .thermal,
            entry: entry,
            emptyHint: entry.snapshot.maxCelsius == nil ? "温度模块" : nil
        ) {
            let model = ThermalCardModel.from(snapshot: entry.snapshot)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.tempText ?? "--")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.color(for: model.tier))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(model.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                // A6·2：温度超阈值整卡红色描边——比变色大字更醒目的越线信号
                if model.isCritical {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red, lineWidth: 2)
                }
            }
        }
    }

    private static func color(for tier: HeatTier) -> Color {
        switch tier {
        case .normal: return .primary
        case .hot: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - WG-03 风扇

public struct FanWidgetView: View {
    public let entry: TimelineEntry

    public init(entry: TimelineEntry) {
        self.entry = entry
    }

    public var body: some View {
        WidgetCardShell(
            kind: .fan,
            entry: entry,
            // 风扇属温控模块（A5），空态文案随模块不随族
            emptyHint: entry.snapshot.fanAverageRPM == nil ? "温度模块" : nil
        ) {
            let model = FanCardModel.from(snapshot: entry.snapshot)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.rpmText ?? "--")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(model.modeBadge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - WG-04 性能

public struct PerformanceWidgetView: View {
    public let entry: TimelineEntry
    /// CPU/内存文本由组装方喂（快照契约无性能域，T-054c 接采样器后改喂快照字段）；nil → "--"
    public let cpuText: String?
    public let memText: String?

    public init(entry: TimelineEntry, cpuText: String? = nil, memText: String? = nil) {
        self.entry = entry
        self.cpuText = cpuText
        self.memText = memText
    }

    public var body: some View {
        WidgetCardShell(kind: .performance, entry: entry) {
            let model = PerformanceCardModel.from(
                net: entry.snapshot.netBytesPerSec, cpuText: cpuText, memText: memText
            )
            VStack(alignment: .leading, spacing: 5) {
                Self.line(model.cpuLine)
                Self.line(model.memLine)
                Self.line(model.netLine)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static func line(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

// MARK: - WG-05 日程 / WG-06 天气（透传卡）

public struct CalendarWidgetView: View {
    public let entry: TimelineEntry
    /// E6 数据不在快照契约内：组装方喂现值；nil/占位 → 空态
    public let model: CalendarCardModel?

    public init(entry: TimelineEntry, model: CalendarCardModel? = nil) {
        self.entry = entry
        self.model = model
    }

    public var body: some View {
        WidgetCardShell(
            kind: .calendar,
            entry: entry,
            emptyHint: (model?.isPlaceholder ?? true) ? "日程模块" : nil
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: model?.symbol ?? "calendar")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(model?.valueText ?? "")
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let detail = model?.detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

public struct WeatherWidgetView: View {
    public let entry: TimelineEntry
    /// E5 数据不在快照契约内：组装方喂现值；nil/占位 → 空态
    public let model: WeatherCardModel?

    public init(entry: TimelineEntry, model: WeatherCardModel? = nil) {
        self.entry = entry
        self.model = model
    }

    public var body: some View {
        WidgetCardShell(
            kind: .weather,
            entry: entry,
            emptyHint: (model?.isPlaceholder ?? true) ? "天气模块" : nil
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: model?.symbol ?? "cloud.sun")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(model?.valueText ?? "")
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let detail = model?.detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - TimelineProvider（A6·4）

/// ButlerTimelineProvider：WidgetKit 协议壳。时间线生成逻辑全部收敛在 ButlerTimelineFactory
/// （可测内核）——Context 在单测里造不出来，壳里不留任何分支。
public struct ButlerTimelineProvider: TimelineProvider {
    /// 快照目录注入：扩展 target 用默认共享目录（A6·4 非沙盒红利），测试可指临时目录
    private let writer: WidgetSnapshotWriter

    public init(directory: URL = WidgetSnapshotWriter.defaultDirectory()) {
        self.writer = WidgetSnapshotWriter(directory: directory)
    }

    public func placeholder(in context: Context) -> TimelineEntry {
        // 系统画廊/列表占位：用 empty 快照走各族空态，绝不拿真数据冒充演示（隐私口径）
        TimelineEntry(date: Date(), snapshot: .empty, isStale: false)
    }

    public func getSnapshot(in context: Context, completion: @escaping (TimelineEntry) -> Void) {
        // 读得到就给真数据（首帧/画廊）；读不到退 empty 占位——与 timeline 的降级同一路径
        let snapshot = writer.read() ?? .empty
        completion(TimelineEntry(date: Date(), snapshot: snapshot, isStale: false))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<TimelineEntry>) -> Void) {
        completion(timeline())
    }

    /// 时间线（A6·4）：读快照 → 5 分钟步进平铺 5 条，越远越旧、isStale 逐条点亮；
    /// atEnd 让系统在最后一条到期后回来要新时间线（配合主 App 的 Darwin 通知双轨）
    public func timeline(now: Date = Date()) -> Timeline<TimelineEntry> {
        Timeline(
            entries: ButlerTimelineFactory.entries(now: now, writer: writer),
            policy: .atEnd
        )
    }
}
#endif
