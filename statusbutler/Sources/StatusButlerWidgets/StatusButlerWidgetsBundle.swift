import WidgetKit
import SwiftUI
import StatusButlerCore

// T-054（A6·2/A6·5）扩展进程入口：@main 只做"按族注册表组装"。
// 视图/Provider/时间线/显示模型全在 StatusButlerCore（WidgetUI/WidgetData）——两端一套口径；
// 加族 = Core 注册表加 case（WidgetFamilyMapTests 编译期穷举 + 用例爆红）+ 这里补一个壳类型与一行声明。

/// 入口视图壳：makeView 工厂是 @MainActor（Swift 6 View 隔离随协议推断），
/// StaticConfiguration 的 content 闭包不保证主隔离——壳把工厂调用挪进 body（天然主隔离），闭包侧零隔离要求
private struct ButlerWidgetEntryView: View {
    let kind: ButlerWidgetKind
    // 限定模块名：WidgetKit 有同名 TimelineEntry 协议，裸名在双 import 下二义（Core 内部靠声明序掩盖，跨模块躲不开）
    let entry: StatusButlerCore.TimelineEntry

    var body: some View {
        kind.makeView(entry: entry)
    }
}

/// 六族共用的配置工厂：展示名/描述/支持尺寸/Provider 全读 WidgetFamilyMap 注册表与 Core 的
/// ButlerTimelineProvider，本文件不出现第二份元数据。@MainActor：configurationDisplayName 等
/// 配置修饰符是主隔离实例方法，非隔离工厂里调不动（Widget.body 本就在主隔离，调用点无额外代价）
@MainActor
private func butlerConfiguration(for kind: ButlerWidgetKind) -> some WidgetConfiguration {
    let descriptor = WidgetFamilyMap.descriptor(for: kind)
    return StaticConfiguration(kind: kind.rawValue, provider: ButlerTimelineProvider()) { entry in
        ButlerWidgetEntryView(kind: kind, entry: entry)
    }
    .configurationDisplayName(descriptor.displayName)
    .description(descriptor.subtitle)
    .supportedFamilies(kind.widgetFamilies)
}

// Widget 协议钉死 init()（WidgetBundle 按类型无参构造），参数化不成立——
// 一族一个零逻辑壳类型，全部委托上面的共用工厂
private struct OverviewButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .overview) }
}

private struct ThermalButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .thermal) }
}

private struct FanButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .fan) }
}

private struct PerformanceButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .performance) }
}

private struct CalendarButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .calendar) }
}

private struct WeatherButlerWidget: Widget {
    var body: some WidgetConfiguration { butlerConfiguration(for: .weather) }
}

@main
struct StatusButlerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // 与 ButlerWidgetKind.allCases 同序（组件库展示顺序即注册表顺序）
        OverviewButlerWidget()
        ThermalButlerWidget()
        FanButlerWidget()
        PerformanceButlerWidget()
        CalendarButlerWidget()
        WeatherButlerWidget()
    }
}
