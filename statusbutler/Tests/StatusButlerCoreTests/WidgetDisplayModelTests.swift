import Foundation
import Testing
@testable import StatusButlerCore

// T-054b: 小组件显示模型层——六族 from 映射全分支、热度档位边界、陈旧档位与文案、
// 时间线工厂（注入临时目录）；视图不直测（AGENTS·验证门），视图所需的一切判定都在这里钉死

@Suite(.serialized) struct WidgetDisplayModelTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "widget-ui-tests-\(UUID().uuidString)")
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

    // MARK: - WG-01 管家总览

    @Test func overviewMapsFullyPopulatedSnapshot() {
        let model = OverviewCardModel.from(snapshot: fullSnapshot())
        // 87 落 battery.75 档（<88），充电叠 bolt——符号档位与文案同源断言
        #expect(model.battery == OverviewCellModel(
            symbolName: "battery.75.bolt", valueText: "87%", caption: "正在充电"
        ))
        #expect(model.signal == OverviewCellModel(symbolName: "wifi", valueText: "Home", caption: "▮▮▮▯"))
        // 60% → round(0.6×4)=2 点，与菜单栏图标同公式（两端一致）
        #expect(model.volume == OverviewCellModel(
            symbolName: "speaker.wave.2", valueText: "60%", caption: "●●○○"
        ))
        // 78.5 四舍五入 → 79°
        #expect(model.temperature == OverviewCellModel(symbolName: "thermometer", valueText: "79°", caption: "最高温"))
        #expect(model.fanLine == "风扇 2450 RPM")
    }

    @Test func overviewBatteryUnavailableShowsPlaceholderNotZero() {
        var snapshot = fullSnapshot()
        snapshot.battery = .unavailable
        #expect(OverviewCardModel.from(snapshot: snapshot).battery
            == OverviewCellModel(symbolName: "battery.0", valueText: "--", caption: "无电池"))
        // 域整体缺失（主 App 未采样）与 unavailable 同形态——绝不显示误导性的 0%
        snapshot.battery = nil
        #expect(OverviewCardModel.from(snapshot: snapshot).battery.valueText == "--")
        // 符号档位边界：12→0 档、13→25 档、88→100 档；充电后缀 bolt
        #expect(OverviewCardModel.batterySymbol(level: 12, charging: false) == "battery.0")
        #expect(OverviewCardModel.batterySymbol(level: 13, charging: false) == "battery.25")
        #expect(OverviewCardModel.batterySymbol(level: 88, charging: true) == "battery.100.bolt")
    }

    @Test func overviewSignalVariantsMapBarsAndSymbols() {
        var snapshot = fullSnapshot()
        snapshot.link = .wired
        #expect(OverviewCardModel.from(snapshot: snapshot).signal
            == OverviewCellModel(symbolName: "antenna.radiowaves.left.and.right", valueText: "有线", caption: "▮▮▮▮"))
        snapshot.link = .offline
        #expect(OverviewCardModel.from(snapshot: snapshot).signal
            == OverviewCellModel(symbolName: "wifi.slash", valueText: "离线", caption: "▯▯▯▯"))
        snapshot.link = .wifi(ssid: nil, signalBars: 2)
        #expect(OverviewCardModel.from(snapshot: snapshot).signal
            == OverviewCellModel(symbolName: "wifi", valueText: "Wi-Fi", caption: "▮▮▯▯"))
        snapshot.link = nil
        #expect(OverviewCardModel.from(snapshot: snapshot).signal
            == OverviewCellModel(symbolName: "wifi", valueText: "--", caption: "--"))
        // 字形钳制：越界输入不炸不越 4 格
        #expect(OverviewCardModel.barsGlyph(9) == "▮▮▮▮")
        #expect(OverviewCardModel.barsGlyph(-1) == "▯▯▯▯")
    }

    @Test func overviewVolumeDotsFollowIconFormulaAndMuteOverrides() {
        var snapshot = fullSnapshot()
        snapshot.volume = VolumeState(level: 50, isMuted: false)
        #expect(OverviewCardModel.from(snapshot: snapshot).volume.caption == "●●○○")
        snapshot.volume = VolumeState(level: 100, isMuted: false)
        #expect(OverviewCardModel.from(snapshot: snapshot).volume.caption == "●●●●")
        // 静音优先于音量：80% 静音也是零点 + 专用符号与文案
        snapshot.volume = VolumeState(level: 80, isMuted: true)
        #expect(OverviewCardModel.from(snapshot: snapshot).volume
            == OverviewCellModel(symbolName: "speaker.slash.fill", valueText: "80%", caption: "已静音"))
        #expect(OverviewCardModel.volumeDots(level: 80, isMuted: true) == 0)
        #expect(OverviewCardModel.dotsGlyph(1) == "●○○○")
        snapshot.volume = nil
        #expect(OverviewCardModel.from(snapshot: snapshot).volume.valueText == "--")
    }

    @Test func overviewMissingTempAndFanDegradePerCell() {
        var snapshot = fullSnapshot()
        snapshot.maxCelsius = nil
        snapshot.fanAverageRPM = nil
        let model = OverviewCardModel.from(snapshot: snapshot)
        #expect(model.temperature
            == OverviewCellModel(symbolName: "thermometer", valueText: "--", caption: "温度未启用"))
        #expect(model.fanLine == nil)  // 无风扇数据不占 M 尺寸附加行
        #expect(model.battery.valueText == "87%")  // 其余格不受牵连
    }

    // MARK: - WG-02 温度

    @Test func thermalMapsTempTierAndSource() {
        let model = ThermalCardModel.from(snapshot: fullSnapshot())
        #expect(model.tempText == "79°")
        #expect(model.tier == .normal)
        #expect(model.sourceText == "全机最高")
        #expect(!model.isCritical)
        // 无温度 → 视图走空态：tempText nil + 模块提示副行
        var snapshot = fullSnapshot()
        snapshot.maxCelsius = nil
        let empty = ThermalCardModel.from(snapshot: snapshot)
        #expect(empty.tempText == nil)
        #expect(empty.tier == .normal)
        #expect(empty.sourceText == "温度模块未启用")
    }

    @Test func thermalTierBoundariesAreStrictlyGreaterThan() {
        // 任务钉的边界：79.9/80/90——80 恰在 warn 线上仍 normal，90 恰在 critical 线上仍 hot
        #expect(HeatTier.tier(celsius: 79.9) == .normal)
        #expect(HeatTier.tier(celsius: 80) == .normal)
        #expect(HeatTier.tier(celsius: 80.1) == .hot)
        #expect(HeatTier.tier(celsius: 90) == .hot)
        #expect(HeatTier.tier(celsius: 90.1) == .critical)
        var snapshot = fullSnapshot()
        snapshot.maxCelsius = 95
        #expect(ThermalCardModel.from(snapshot: snapshot).isCritical)
    }

    // MARK: - WG-03 风扇

    @Test func fanMapsRpmAndModeBadges() {
        let model = FanCardModel.from(snapshot: fullSnapshot())
        #expect(model.rpmText == "2450 RPM")
        #expect(model.modeBadge == "跟随系统")  // 契约无模式字段，默认跟随系统
        var snapshot = fullSnapshot()
        snapshot.fanAverageRPM = nil
        #expect(FanCardModel.from(snapshot: snapshot).rpmText == nil)
        // 三模式徽标文案钉死（快照加模式字段前调用方按此喂）
        #expect(FanCardModel.badge(for: .system) == "跟随系统")
        #expect(FanCardModel.badge(for: .constant) == "恒速")
        #expect(FanCardModel.badge(for: .curve) == "曲线")
        #expect(FanCardModel.from(snapshot: fullSnapshot(), mode: .constant).modeBadge == "恒速")
    }

    // MARK: - WG-04 性能

    @Test func performancePassthroughTextsAndNetLine() {
        // 本版 CPU/MEM 由调用方喂（T-054c 接采样器）；缺喂降级 "--"
        let blank = PerformanceCardModel.from(net: nil)
        #expect(blank.cpuLine == "CPU --")
        #expect(blank.memLine == "MEM --")
        #expect(blank.netLine == "NET --")
        let fed = PerformanceCardModel.from(net: fullSnapshot().netBytesPerSec, cpuText: "32%", memText: "12.4/36 GB")
        #expect(fed.cpuLine == "CPU 32%")
        #expect(fed.memLine == "MEM 12.4/36 GB")
        // ↑ 上行(out)=512 B/s、↓ 下行(in)=2048=2.0 KB/s
        #expect(fed.netLine == "NET ↑ 512 B/s · ↓ 2.0 KB/s")
    }

    @Test func performanceByteRateUnitsAcrossScales() {
        #expect(PerformanceCardModel.byteRate(0) == "0 B/s")
        #expect(PerformanceCardModel.byteRate(512) == "512 B/s")
        #expect(PerformanceCardModel.byteRate(1023) == "1023 B/s")
        #expect(PerformanceCardModel.byteRate(1024) == "1.0 KB/s")
        #expect(PerformanceCardModel.byteRate(2048) == "2.0 KB/s")
        #expect(PerformanceCardModel.byteRate(2 * 1024 * 1024) == "2.0 MB/s")
        #expect(PerformanceCardModel.byteRate(1_500_000_000) == "1.4 GB/s")
        // 计数器翻转的负差值钳 0——展示层绝不出现"负网速"
        #expect(PerformanceCardModel.byteRate(-4096) == "0 B/s")
    }

    // MARK: - WG-05/06 日程与天气（透传）

    @Test func weatherAndCalendarModelsPassThroughAndFlagPlaceholder() {
        let weather = WeatherCardModel(symbol: "sun.max", valueText: "26° 晴", detailText: "明天 18–27° · AQI 45")
        #expect(weather.valueText == "26° 晴")
        #expect(weather.detailText == "明天 18–27° · AQI 45")
        #expect(!weather.isPlaceholder)
        #expect(WeatherCardModel.placeholder.isPlaceholder)
        #expect(WeatherCardModel().valueText.isEmpty)  // 默认即占位

        let calendar = CalendarCardModel(symbol: "clock", valueText: "14:00 评审会", detailText: "还有 25 分")
        #expect(calendar.valueText == "14:00 评审会")
        #expect(calendar.detailText == "还有 25 分")
        #expect(!calendar.isPlaceholder)
        #expect(CalendarCardModel.placeholder.isPlaceholder)
    }

    // MARK: - 陈旧标注（A6·4）

    @Test func staleStyleTiersAndThresholdBoundary() {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // 118/120 均新鲜——恰在阈值（120s）不算"超过"，与 WidgetTimeline.staleness 同口径
        #expect(StaleStyle.for(age: 118, generatedAt: generatedAt) == StaleStyle(opacity: 1.0, restingText: nil))
        #expect(StaleStyle.for(age: 120, generatedAt: generatedAt).restingText == nil)
        // 300s → 陈旧档：半透明 + "管家休息中 · HH:mm 数据"（时刻取快照生成时间）
        let stale = StaleStyle.for(age: 300, generatedAt: generatedAt)
        #expect(stale.opacity == 0.55)
        #expect(stale.restingText == "管家休息中 · \(StaleStyle.hourMinute(generatedAt)) 数据")
        // >10 分钟 → 深陈旧档更淡，文案不变
        #expect(StaleStyle.for(age: 601, generatedAt: generatedAt).opacity == 0.35)
        #expect(StaleStyle.for(age: 601, generatedAt: generatedAt).restingText == stale.restingText)
    }

    @Test func staleStyleHourMinuteIsFixedTwentyFourHourShape() {
        // 固定 HH:mm 两位数字形态（时区无关断言：不钉具体时刻只钉形态，CI 任何时区都成立）
        let pattern = "^\\d{2}:\\d{2}$"
        for offset in [0, 3661, 86_399] {
            let text = StaleStyle.hourMinute(Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset)))
            #expect(text.range(of: pattern, options: .regularExpression) != nil)
        }
    }

    // MARK: - 时间线工厂（TimelineProvider 可测内核）

    @Test func timelineFactoryExtrapolatesFromWrittenSnapshot() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(directory: dir, notifier: FakeQuietNotifier())
        // 快照生成于 100s 前：步进 60s×5 条 → 数据年龄 100/160/220/280/340，阈值 120 严格大于
        let now = Date(timeIntervalSince1970: 1_000_000)
        try writer.write(WidgetSnapshot(generatedAt: now.addingTimeInterval(-100), maxCelsius: 55))

        let entries = ButlerTimelineFactory.entries(now: now, writer: writer, stepSeconds: 60, count: 5)
        #expect(entries.count == 5)
        #expect(entries.map(\.isStale) == [false, true, true, true, true])
        // 无历史样本 → 斜率 0 平铺（扩展进程不留历史缓冲，A6·6）
        #expect(entries.map(\.snapshot.maxCelsius).compactMap { $0 } == [55, 55, 55, 55, 55])
        #expect(entries[1].date == now.addingTimeInterval(60))
        #expect(entries[4].date == now.addingTimeInterval(240))
    }

    @Test func timelineFactoryMissingFileFallsBackToEmptySnapshot() {
        let writer = WidgetSnapshotWriter(directory: makeDirectory(), notifier: FakeQuietNotifier())
        let now = Date(timeIntervalSince1970: 2_000_000)
        // 默认步进 300s×5：空快照 generatedAt=now → 年龄 0/300/600/900/1200 → 陈旧逐条点亮
        let entries = ButlerTimelineFactory.entries(now: now, writer: writer)
        #expect(entries.count == 5)
        #expect(entries.map(\.isStale) == [false, true, true, true, true])
        #expect(entries.allSatisfy { $0.snapshot.battery == nil && $0.snapshot.maxCelsius == nil })
        #expect(entries.allSatisfy { $0.snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion })
        #expect(entries[3].date == now.addingTimeInterval(900))
        // count 参数透传
        #expect(ButlerTimelineFactory.entries(now: now, writer: writer, count: 3).count == 3)
    }

    /// TimelineProvider 读路径不关心通知（通知是写侧事）；测试注入零噪音假实现
    private struct FakeQuietNotifier: NotifierPostable, @unchecked Sendable {
        func post(_ name: String) {}
    }
}
