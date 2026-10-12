// T-054b 族注册纯表（A6·2）：六族组件的元数据一处登记。
// 元数据段零 UI 依赖（Core 内可单测）；视图工厂挂在 WidgetKit/SwiftUI 保护段——
// 扩展 target 的 @main 只按本表组装，新增组件 = 加一个 case + 一个 switch 分支，两端永不各写一份。
#if canImport(Foundation)
import Foundation

/// 小组件族标识（WG-01~06）。rawValue 同时是将来 WidgetBundleConfiguration 的稳定 id
public enum ButlerWidgetKind: String, CaseIterable, Sendable, Equatable {
    case overview       // WG-01 管家总览
    case thermal        // WG-02 温度
    case fan            // WG-03 风扇
    case performance    // WG-04 性能
    case calendar       // WG-05 日程
    case weather        // WG-06 天气
}

/// 族描述子：展示名/深链/尺寸/对应显示模型——全字符串形态，注册表自检（非空）即可测
public struct ButlerWidgetDescriptor: Equatable, Sendable {
    public let kind: ButlerWidgetKind
    public let displayName: String
    public let subtitle: String
    /// widgetURL 深链（A6·3 butler://panel/*）；必须落在 ButlerCommand.allowed 白名单内，
    /// 未上白名单的面板先指 panel/show 兜底，面板动词上白名单后再改指分区
    public let deepLink: String
    /// 支持尺寸（A6·2 约定）：S/M/L/XL；WidgetFamily 的实际换算在视图工厂段
    public let sizes: String
    /// 对应显示模型类型名——注册表自检用（防止加族忘配模型）
    public let modelName: String

    public init(
        kind: ButlerWidgetKind,
        displayName: String,
        subtitle: String,
        deepLink: String,
        sizes: String,
        modelName: String
    ) {
        self.kind = kind
        self.displayName = displayName
        self.subtitle = subtitle
        self.deepLink = deepLink
        self.sizes = sizes
        self.modelName = modelName
    }
}

public enum WidgetFamilyMap {
    /// 全表（顺序即组件库展示顺序）。descriptor(for:) 是唯一构造源，
    /// switch 穷举编译器钉死：加 case 不配表直接红，不会静默漏族
    public static var all: [ButlerWidgetDescriptor] {
        ButlerWidgetKind.allCases.map { descriptor(for: $0) }
    }

    public static func descriptor(for kind: ButlerWidgetKind) -> ButlerWidgetDescriptor {
        switch kind {
        case .overview:
            return ButlerWidgetDescriptor(
                kind: .overview, displayName: "管家总览", subtitle: "电量·网络·音量·温度四格",
                deepLink: "butler://panel/show", sizes: "S/M", modelName: "OverviewCardModel"
            )
        case .thermal:
            return ButlerWidgetDescriptor(
                kind: .thermal, displayName: "温度", subtitle: "全机最高温与热度档",
                deepLink: "butler://panel/thermal", sizes: "S/M/L", modelName: "ThermalCardModel"
            )
        case .fan:
            return ButlerWidgetDescriptor(
                kind: .fan, displayName: "风扇", subtitle: "平均转速与模式徽标",
                deepLink: "butler://panel/thermal", sizes: "S", modelName: "FanCardModel"
            )
        case .performance:
            return ButlerWidgetDescriptor(
                kind: .performance, displayName: "性能", subtitle: "CPU·内存·网速三行",
                // 性能分区深链动词未上白名单（面板随 T-054c 扩展），先落总面板
                deepLink: "butler://panel/show", sizes: "S/M/L", modelName: "PerformanceCardModel"
            )
        case .calendar:
            return ButlerWidgetDescriptor(
                kind: .calendar, displayName: "日程", subtitle: "下一件事与倒数",
                deepLink: "butler://panel/show", sizes: "S/M", modelName: "CalendarCardModel"
            )
        case .weather:
            return ButlerWidgetDescriptor(
                kind: .weather, displayName: "天气", subtitle: "当前天气与明日概览",
                deepLink: "butler://panel/show", sizes: "S/M", modelName: "WeatherCardModel"
            )
        }
    }
}
#endif

#if canImport(WidgetKit) && canImport(SwiftUI)
import WidgetKit
import SwiftUI

public extension ButlerWidgetKind {
    /// 尺寸换算：注册表 sizes 字段（S/M/L）→ WidgetFamily。只报组件真正适配过的尺寸，
    /// 不逐族照抄 A6 全档位——视图按 S/M 自适应设计（任务口径），L 档留给后续任务
    var widgetFamilies: [WidgetFamily] {
        switch self {
        case .overview, .calendar, .weather:
            return [.systemSmall, .systemMedium]
        case .thermal, .performance:
            return [.systemSmall, .systemMedium, .systemLarge]
        case .fan:
            return [.systemSmall]
        }
    }

    /// 视图工厂：扩展 target @main 组装入口（一族一视图）。
    /// weather/calendar 数据源不在快照契约内，组装方喂现值（nil → 占位空态）。
    /// @MainActor：View 的 init 随协议推断主隔离（Swift 6），工厂必须同域才能同步构造
    @MainActor
    @ViewBuilder
    func makeView(
        entry: TimelineEntry,
        weather: WeatherCardModel? = nil,
        calendar: CalendarCardModel? = nil
    ) -> some View {
        switch self {
        case .overview:
            OverviewWidgetView(entry: entry)
        case .thermal:
            ThermalWidgetView(entry: entry)
        case .fan:
            FanWidgetView(entry: entry)
        case .performance:
            PerformanceWidgetView(entry: entry)
        case .calendar:
            CalendarWidgetView(entry: entry, model: calendar)
        case .weather:
            WeatherWidgetView(entry: entry, model: weather)
        }
    }
}
#endif
