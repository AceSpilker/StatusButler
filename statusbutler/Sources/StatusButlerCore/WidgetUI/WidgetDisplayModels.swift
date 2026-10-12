#if canImport(Foundation)
import Foundation

// T-054b 小组件显示模型层（A6·2 WG-01~06）：快照 → 卡片视图模型的纯映射。
// 本文件零 UI 依赖——视图（ButlerWidgetViews）只管布局，一切分支/格式化/文案在此钉死并可单测；
// 迁移到 WidgetKit 扩展 target 时原样带走，Core 里的测试继续覆盖同一份映射（两端一套口径）。

extension WidgetSnapshot {
    /// 空快照：全部可选域为 nil、生成时间取当下。placeholder/getSnapshot 与"读不到文件"时的占位形态
    /// （A6·4）——视图层据此走各族的"模块未启用"空态，而不是渲染出半截数据。
    public static var empty: WidgetSnapshot { WidgetSnapshot(generatedAt: Date()) }
}

// MARK: - WG-01 管家总览卡

/// 四格单元：SF Symbol + 主值 + 副说明，全部预格式化字符串（等宽数字由视图统一施加）
public struct OverviewCellModel: Equatable, Sendable {
    public var symbolName: String
    public var valueText: String
    public var caption: String

    public init(symbolName: String, valueText: String, caption: String) {
        self.symbolName = symbolName
        self.valueText = valueText
        self.caption = caption
    }
}

/// 管家总览（菜单栏三合一图标的桌面版）：S 四格；M 追加风扇行
public struct OverviewCardModel: Equatable, Sendable {
    public var battery: OverviewCellModel
    public var signal: OverviewCellModel
    public var volume: OverviewCellModel
    public var temperature: OverviewCellModel
    /// M 尺寸附加行（A6 WG-01：M 加风扇 RPM）；无风扇数据为 nil 不占行
    public var fanLine: String?

    public init(
        battery: OverviewCellModel,
        signal: OverviewCellModel,
        volume: OverviewCellModel,
        temperature: OverviewCellModel,
        fanLine: String? = nil
    ) {
        self.battery = battery
        self.signal = signal
        self.volume = volume
        self.temperature = temperature
        self.fanLine = fanLine
    }

    public static func from(snapshot: WidgetSnapshot) -> OverviewCardModel {
        OverviewCardModel(
            battery: batteryCell(snapshot.battery),
            signal: signalCell(snapshot.link),
            volume: volumeCell(snapshot.volume),
            temperature: tempCell(snapshot.maxCelsius),
            fanLine: snapshot.fanAverageRPM.map { "风扇 \($0) RPM" }
        )
    }

    /// 电量符号按区间对齐 SF Symbol 档位（25% 一档）；充电叠 .bolt。
    /// 档位边界取 12.5/37.5/62.5/87.5 的整级近似（13/38/63/88），避免 74% 与 75% 抢同一档
    public static func batterySymbol(level: Int, charging: Bool) -> String {
        let base: String
        switch level {
        case ..<13: base = "battery.0"
        case ..<38: base = "battery.25"
        case ..<63: base = "battery.50"
        case ..<88: base = "battery.75"
        default: base = "battery.100"
        }
        return charging ? base + ".bolt" : base
    }

    private static func batteryCell(_ battery: BatteryState?) -> OverviewCellModel {
        guard case .battery(let level, let charging) = battery else {
            // 无电池（台式机/域未采样）与 .unavailable 同形态：显式 "--" 而非 0%，不误导
            return OverviewCellModel(symbolName: "battery.0", valueText: "--", caption: "无电池")
        }
        return OverviewCellModel(
            symbolName: batterySymbol(level: level, charging: charging),
            valueText: "\(level)%",
            caption: charging ? "正在充电" : "电量"
        )
    }

    /// 信号格字形：▮▮▮▯。有线按图标口径视为满格（E1 同款），离线空格——两端同一套语系
    private static func signalCell(_ link: NetworkLink?) -> OverviewCellModel {
        switch link {
        case .wifi(let ssid, let bars):
            return OverviewCellModel(symbolName: "wifi", valueText: ssid ?? "Wi-Fi", caption: barsGlyph(bars))
        case .wired:
            return OverviewCellModel(symbolName: "antenna.radiowaves.left.and.right", valueText: "有线", caption: barsGlyph(4))
        case .offline:
            return OverviewCellModel(symbolName: "wifi.slash", valueText: "离线", caption: barsGlyph(0))
        case nil:
            return OverviewCellModel(symbolName: "wifi", valueText: "--", caption: "--")
        }
    }

    private static func volumeCell(_ volume: VolumeState?) -> OverviewCellModel {
        guard let volume else {
            return OverviewCellModel(symbolName: "speaker.wave.2", valueText: "--", caption: "--")
        }
        let dots = volumeDots(level: volume.level, isMuted: volume.isMuted)
        return OverviewCellModel(
            symbolName: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
            valueText: "\(volume.level)%",
            caption: volume.isMuted ? "已静音" : dotsGlyph(dots)
        )
    }

    private static func tempCell(_ celsius: Double?) -> OverviewCellModel {
        guard let celsius else {
            return OverviewCellModel(symbolName: "thermometer", valueText: "--", caption: "温度未启用")
        }
        return OverviewCellModel(symbolName: "thermometer", valueText: tempText(celsius), caption: "最高温")
    }

    /// 温度大字统一入口：四舍五入取整 + "°"（78.5 → "79°"）——总览/温度两族同一格式，
    /// 总览格与大字卡刷新时刻不一致也不会出现两个口径
    public static func tempText(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    /// 音量四点：与菜单栏图标（IconSceneState）同公式 round(level/100×4)，静音归零——两端必须一致
    public static func volumeDots(level: Int, isMuted: Bool) -> Int {
        guard !isMuted else { return 0 }
        return min(max(Int((Double(level) / 100.0 * 4.0).rounded()), 0), 4)
    }

    public static func barsGlyph(_ bars: Int) -> String {
        let clamped = min(max(bars, 0), 4)
        return String(repeating: "▮", count: clamped) + String(repeating: "▯", count: 4 - clamped)
    }

    public static func dotsGlyph(_ dots: Int) -> String {
        let clamped = min(max(dots, 0), 4)
        return String(repeating: "●", count: clamped) + String(repeating: "○", count: 4 - clamped)
    }
}

// MARK: - WG-02 温度卡 / WG-03 风扇卡

/// 热度档位（A6·2 温度超阈值整卡红色描边的判定源；A5 同窗口）
public enum HeatTier: Equatable, Sendable {
    case normal
    case hot
    case critical

    /// warn > 80、critical > 90，均严格大于——恰在阈值上不算越线，
    /// 与 WidgetTimeline.staleness 的"超过才算"同一口径（边界可测：80 仍 normal、90 仍 hot）
    public static func tier(celsius: Double) -> HeatTier {
        if celsius > 90 { return .critical }
        if celsius > 80 { return .hot }
        return .normal
    }
}

/// 温度卡：大字温度 + 档位 + 副行来源
public struct ThermalCardModel: Equatable, Sendable {
    /// "78°"；nil = 无温度数据（模块未启用/无传感器）→ 视图走空态
    public var tempText: String?
    public var tier: HeatTier
    /// 副行来源。快照契约（schema 1）只有 maxCelsius 不含传感器名，故统一"全机最高"；
    /// 将来要显示具体传感器名需 schema +1 增字段，不该在显示层猜
    public var sourceText: String

    public var isCritical: Bool { tier == .critical }

    public init(tempText: String?, tier: HeatTier, sourceText: String) {
        self.tempText = tempText
        self.tier = tier
        self.sourceText = sourceText
    }

    public static func from(snapshot: WidgetSnapshot) -> ThermalCardModel {
        guard let celsius = snapshot.maxCelsius else {
            return ThermalCardModel(tempText: nil, tier: .normal, sourceText: "温度模块未启用")
        }
        return ThermalCardModel(
            tempText: OverviewCardModel.tempText(celsius),
            tier: HeatTier.tier(celsius: celsius),
            sourceText: "全机最高"
        )
    }
}

/// 风扇卡：平均转速 + 模式徽标。快照契约（schema 1）不含风扇模式——本版默认 .system，
/// 参数已预留：T-054c 若把模式写进快照（schema +1）只需改调用方喂值，映射层零改动
public struct FanCardModel: Equatable, Sendable {
    /// "2450 RPM"；nil = 无风扇数据（台式无风扇机/模块未启用）
    public var rpmText: String?
    public var modeBadge: String

    public init(rpmText: String?, modeBadge: String) {
        self.rpmText = rpmText
        self.modeBadge = modeBadge
    }

    public static func from(snapshot: WidgetSnapshot, mode: FanMode = .system) -> FanCardModel {
        FanCardModel(
            rpmText: snapshot.fanAverageRPM.map { "\($0) RPM" },
            modeBadge: badge(for: mode)
        )
    }

    public static func badge(for mode: FanMode) -> String {
        switch mode {
        case .system: return "跟随系统"
        case .constant: return "恒速"
        case .curve: return "曲线"
        }
    }
}

// MARK: - WG-04 性能卡

/// 性能卡三行。CPU/内存文本由调用方喂——快照契约（schema 1）尚无性能域，
/// T-054c 接采样器后改喂 snapshot 字段，本函数签名已按"喂文本"设计零迁移
public struct PerformanceCardModel: Equatable, Sendable {
    public var cpuLine: String
    public var memLine: String
    public var netLine: String

    public init(cpuLine: String, memLine: String, netLine: String) {
        self.cpuLine = cpuLine
        self.memLine = memLine
        self.netLine = netLine
    }

    public static func from(
        net: WidgetSnapshot.NetRates?,
        cpuText: String? = nil,
        memText: String? = nil
    ) -> PerformanceCardModel {
        PerformanceCardModel(
            cpuLine: "CPU " + (cpuText ?? "--"),
            memLine: "MEM " + (memText ?? "--"),
            netLine: netLine(rates: net)
        )
    }

    /// ↑ 为上行（out）、↓ 为下行（in）——与 A6 WG-04 演示稿同一朝向
    public static func netLine(rates: WidgetSnapshot.NetRates?) -> String {
        guard let rates else { return "NET --" }
        return "NET ↑ \(byteRate(rates.out)) · ↓ \(byteRate(rates.in))"
    }

    /// B/s → 人读单位，1024 进制：≥1 GB/s 用 GB，≥1 MB/s 用 MB（一位小数），≥1 KB/s 用 KB（一位小数）。
    /// 负值钳 0：采样计数器翻转瞬间会产出负差，展示层绝不显示"负网速"
    public static func byteRate(_ bytesPerSec: Double) -> String {
        let value = max(bytesPerSec, 0)
        let kilo = 1024.0
        switch value {
        case ..<kilo:
            return "\(Int(value)) B/s"
        case ..<(kilo * kilo):
            return String(format: "%.1f KB/s", value / kilo)
        case ..<(kilo * kilo * kilo):
            return String(format: "%.1f MB/s", value / kilo / kilo)
        default:
            return String(format: "%.1f GB/s", value / kilo / kilo / kilo)
        }
    }
}

// MARK: - WG-05 日程卡 / WG-06 天气卡（透传）

/// 日程卡：E6 数据不在小组件快照契约内，扩展侧组装时喂现值；空值即空态
public struct CalendarCardModel: Equatable, Sendable {
    public var symbol: String
    /// "14:00 评审会"
    public var valueText: String
    /// "还有 25 分"
    public var detailText: String?

    public init(symbol: String = "calendar", valueText: String = "", detailText: String? = nil) {
        self.symbol = symbol
        self.valueText = valueText
        self.detailText = detailText
    }

    public static var placeholder: CalendarCardModel { CalendarCardModel() }

    public var isPlaceholder: Bool { valueText.isEmpty }
}

/// 天气卡：E5 数据同上，透传不加工（符号用 SF Name 或 emoji 均可）
public struct WeatherCardModel: Equatable, Sendable {
    public var symbol: String
    /// "26° 晴"
    public var valueText: String
    /// "明天 18–27° · AQI 45"
    public var detailText: String?

    public init(symbol: String = "cloud.sun", valueText: String = "", detailText: String? = nil) {
        self.symbol = symbol
        self.valueText = valueText
        self.detailText = detailText
    }

    public static var placeholder: WeatherCardModel { WeatherCardModel() }

    public var isPlaceholder: Bool { valueText.isEmpty }
}

// MARK: - 陈旧标注（A6·4）

/// 快照超过 2 分钟未更新（主 App 退出/睡眠）→ 数字降透明度 + "管家休息中 · HH:mm 数据"。
/// 档位三级：新鲜 1.0 / 陈旧 0.55 / 深陈旧（>10 分钟）0.35——越旧越淡，但仍可读而非消失
public struct StaleStyle: Equatable, Sendable {
    public var opacity: Double
    public var restingText: String?

    public init(opacity: Double, restingText: String?) {
        self.opacity = opacity
        self.restingText = restingText
    }

    /// age = 渲染时刻 - 快照生成时刻（秒）。恰在阈值（120s）仍算新鲜——严格大于，
    /// 与 WidgetTimeline.staleness 同一口径（刷新预算内不许误报"休息中"）
    public static func `for`(age: TimeInterval, generatedAt: Date) -> StaleStyle {
        if age > 600 {
            return StaleStyle(opacity: 0.35, restingText: restingText(generatedAt: generatedAt))
        }
        if age > WidgetTimeline.defaultStaleThreshold {
            return StaleStyle(opacity: 0.55, restingText: restingText(generatedAt: generatedAt))
        }
        return StaleStyle(opacity: 1.0, restingText: nil)
    }

    /// "管家休息中 · HH:mm 数据"：时刻指快照生成时间（那批数属于那一刻），不是发现陈旧的时刻
    public static func restingText(generatedAt: Date) -> String {
        "管家休息中 · \(hourMinute(generatedAt)) 数据"
    }

    /// HH:mm 固定 24 小时制不随系统 12h 设置摆动。DateFormatter 逐次新建而非静态缓存：
    /// 实例非 Sendable，静态缓存会引入全局共享可变状态破严格并发（WeatherProvider 同款论证）
    public static func hourMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - 时间线工厂（TimelineProvider 的可测内核）

/// ButlerTimelineProvider（WidgetKit 协议壳）只做适配，时间线生成逻辑全在这里——
/// WidgetKit 的 TimelineProvider.Context 无法在单测构造，逻辑必须抽出来才能注入临时目录验证。
/// 外推只做平铺（recentTemps 空 → 斜率 0）：扩展进程不留历史缓冲（A6·6 内存上限），
/// 斜率外推需要的历史只在主 App 内存里，这是 T-054a 定下的分工
public enum ButlerTimelineFactory {
    public static func entries(
        now: Date = Date(),
        writer: WidgetSnapshotWriter,
        stepSeconds: Int = 300,
        count: Int = 5
    ) -> [TimelineEntry] {
        // 读不到（首装/主 App 从未运行/文件损坏）→ empty 快照平铺：组件显示空态占位而非崩溃
        let snapshot = writer.read() ?? WidgetSnapshot(generatedAt: now)
        return WidgetTimeline.extrapolate(
            last: snapshot, recentTemps: [], from: now, stepSeconds: stepSeconds, count: count
        )
    }
}
#endif
