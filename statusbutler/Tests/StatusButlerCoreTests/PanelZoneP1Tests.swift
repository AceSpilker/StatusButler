import AppKit
import Foundation
import os
import Testing

@testable import StatusButlerCore

// C2 弹层区 P1（T-203 性能分区行 / T-204 音频输入行 / T-205 iDevice 占位行 /
// T-207 历史查看页 / T-210 Dock 屏幕坐标锚定半件）。映射纯函数钉死边界，
// VM 集成走注入假件；窗口类用例按 AGENTS 实战经验加能力守卫（无 WindowServer
// 的 CI 跳过——能力探测而非平台白名单）。
@MainActor
@Suite(.serialized)
struct PanelZoneP1Tests {

    // MARK: - 测试假件

    @MainActor
    final class NilBluetoothMonitor: BluetoothMonitoring {
        func read() async -> [BluetoothDeviceInfo] { [] }
    }

    @MainActor
    final class NilThermalMonitor: ThermalMonitoring {
        func read() async -> ThermalSnapshot? { nil }
    }

    /// 性能 provider 计数假件（@Sendable 闭包捕获引用语义计数器）
    final class CountingPerfProvider: @unchecked Sendable {
        // @unchecked 论证：count 仅在 unfair lock 内读写
        private let count = OSAllocatedUnfairLock(initialState: 0)
        let sample = PerfSample(
            cpu: CpuUsage(totalPercent: 23.4, perCore: [80, 40, 20, 10]),
            memory: nil,
            net: nil
        )
        var readCount: Int {
            count.withLock { $0 }
        }
        func call() -> PerfSample? {
            count.withLock { $0 += 1 }
            return sample
        }
    }

    /// 可变历史读假件（验证筛选随数据刷新复位）
    final class MutableHistoryReader: HistoryReading, @unchecked Sendable {
        // @unchecked 论证：daily/events 仅在 unfair lock 内读写
        private let state = OSAllocatedUnfairLock(
            initialState: (daily: [DailyMetricPoint](), events: [EventRow]())
        )

        func set(daily: [DailyMetricPoint], events: [EventRow]) {
            state.withLock { $0 = (daily, events) }
        }

        func dailySeries() -> [DailyMetricPoint] {
            state.withLock { $0.daily }
        }

        func recentEvents(limit: Int) -> [EventRow] {
            state.withLock { Array($0.events.suffix(limit)) }
        }
    }

    @MainActor
    final class ExportRecorder {
        private(set) var calls: [(name: String, content: String)] = []
        @discardableResult
        func handle(_ name: String, _ content: String) -> Bool {
            calls.append((name, content))
            return true
        }
    }

    private func makeStore() -> SystemStatusStore {
        SystemStatusStore(
            battery: StaticBatteryMonitor(.battery(level: 66, charging: false)),
            wifi: StaticWiFiMonitor(.wifi(ssid: "Home", signalBars: 3)),
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
    }

    private func makeVM(
        bypassPollInterval: Duration = .seconds(60),
        perfProvider: PerfSampleProvider? = nil,
        cpuTopologyProvider: CpuTopologyProvider? = nil,
        audioInputProvider: AudioInputStatusProvider? = nil,
        mobileBatteryProvider: MobileBatterySummaryProvider? = nil,
        historyReader: (any HistoryReading)? = nil,
        historyExport: HistoryExportClosure? = nil
    ) -> PanelViewModel {
        PanelViewModel(
            store: makeStore(),
            bluetooth: NilBluetoothMonitor(),
            thermal: NilThermalMonitor(),
            bypassPollInterval: bypassPollInterval,
            perfProvider: perfProvider,
            cpuTopologyProvider: cpuTopologyProvider,
            audioInputProvider: audioInputProvider,
            mobileBatteryProvider: mobileBatteryProvider,
            historyReader: historyReader,
            historyExport: historyExport
        )
    }

    // MARK: - T-203 性能分区

    @Test func perfSectionStaysPlaceholderWithoutProvider() async throws {
        let vm = makeVM()
        #expect(!vm.isPerfAvailable)
        vm.refreshPerfOnce()  // 未接线是安全 no-op
        #expect(vm.perfSample == nil)
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.perfSample == nil)  // 不轮询不显示假零值
        #expect(vm.isBypassSamplingActive)  // 性能未接线不影响既有蓝牙/温度旁路链路
    }

    @Test func perfProviderPolledWhileVisibleAndStopsOnDisappear() async throws {
        let provider = CountingPerfProvider()
        let vm = makeVM(
            bypassPollInterval: .milliseconds(80),
            perfProvider: { provider.call() }
        )
        #expect(vm.isPerfAvailable)
        vm.panelDidAppear()
        try await Task.sleep(for: .milliseconds(500))
        #expect(provider.readCount >= 1)
        #expect(vm.perfSample == provider.sample)  // 最近一帧已发布

        vm.panelWillDisappear()
        let stoppedAt = provider.readCount
        try await Task.sleep(for: .milliseconds(400))
        #expect(provider.readCount == stoppedAt)  // 消失即停（能效铁律）
    }

    @Test func cpuRowMappingValueAndPESubtitle() {
        let cpu = CpuUsage(totalPercent: 23.4, perCore: [80, 40, 20, 10])
        #expect(PerfPanelMapping.cpuValueText(cpu) == "23%")
        #expect(PerfPanelMapping.cpuValueText(nil) == "—")
        // P 在前 E 在后（mach 核序）：P=(80+40)/2=60%，E=(20+10)/2=15%
        let topology = CpuCoreTopology(performanceCores: 2, efficiencyCores: 2)
        #expect(PerfPanelMapping.cpuGroupText(cpu: cpu, topology: topology) == "P 60% · E 15%")
        #expect(PerfPanelMapping.cpuSubtitleText(cpu: cpu, topology: topology) == "P 60% · E 15%")
        // 拓扑缺失 → 只显示核数（不猜分组）
        #expect(PerfPanelMapping.cpuGroupText(cpu: cpu, topology: nil) == nil)
        #expect(PerfPanelMapping.cpuSubtitleText(cpu: cpu, topology: nil) == "共 4 逻辑核")
        #expect(PerfPanelMapping.cpuSubtitleText(cpu: nil, topology: nil) == "CPU 不可用")
    }

    @Test func cpuGroupDerivationRejectsTopologyMismatch() {
        let cpu = CpuUsage(totalPercent: 10, perCore: [10, 20, 30])
        // P+E 与每核数不符 → 不猜
        #expect(PerfPanelMapping.cpuGroupText(
            cpu: cpu, topology: CpuCoreTopology(performanceCores: 2, efficiencyCores: 2)
        ) == nil)
        #expect(PerfPanelMapping.cpuGroupText(
            cpu: cpu, topology: CpuCoreTopology(performanceCores: 3, efficiencyCores: 0)
        ) == "P 20% · E 0%")
        // 每核数组为空 → 无分组
        #expect(PerfPanelMapping.cpuGroupText(
            cpu: CpuUsage(totalPercent: 5, perCore: []),
            topology: CpuCoreTopology(performanceCores: 2, efficiencyCores: 2)
        ) == nil)
        #expect(PerfPanelMapping.cpuSubtitleText(
            cpu: CpuUsage(totalPercent: 5, perCore: []), topology: nil
        ) == "CPU 总占用")
    }

    @Test func memoryRowMappingUsedTotalAndPressureTiers() {
        let memory = MemoryUsage(
            totalBytes: 16 * 1024 * 1024 * 1024,
            usedBytes: 10 * 1024 * 1024 * 1024,
            wiredBytes: 0, compressedBytes: 0, freeBytes: 0, swapUsedBytes: 0
        )
        let texts = PerfPanelMapping.memoryTexts(memory)
        #expect(texts.value == "10 GB/16 GB")
        #expect(texts.subtitle == "内存 · 宽裕")  // 62.5%
        // 门限边界：0.7 偏高 / 0.9 紧张（同值域除法与字面量同双精度，边界钉死）
        #expect(MemoryPressureTier.tier(usedBytes: 7, totalBytes: 10) == .elevated)
        #expect(MemoryPressureTier.tier(usedBytes: 9, totalBytes: 10) == .critical)
        #expect(MemoryPressureTier.tier(usedBytes: 0, totalBytes: 0) == nil)  // 防除零
        let missing = PerfPanelMapping.memoryTexts(nil)
        #expect(missing.value == "—" && missing.subtitle == "内存不可用")
    }

    @Test func netRowMappingReadableUpDownRates() {
        let net = NetRates(bytesInPerSec: 1500 * 1024, bytesOutPerSec: 12 * 1024 * 1024)
        let texts = PerfPanelMapping.netTexts(net)
        #expect(texts.value == "↓ 1.5 MB/s · ↑ 12 MB/s")
        #expect(PerfPanelMapping.byteText(0) == "0 B")
        #expect(PerfPanelMapping.byteText(512) == "512 B")
        #expect(PerfPanelMapping.rateText(2048) == "2.0 KB/s")
        let missing = PerfPanelMapping.netTexts(nil)
        #expect(missing.value == "—" && missing.subtitle == "网速不可用")
    }

    @Test func gpuRowFallbackChainAndDoubleNilHides() {
        // activePercent 优先；功率降为副标题
        let both = PerfPanelMapping.gpuTexts(GpuUsage(activePercent: 45.2, powerMilliwatts: 1800))
        #expect(both.value == "45%")
        #expect(both.subtitle == "~1800 mW")
        let percentOnly = PerfPanelMapping.gpuTexts(GpuUsage(activePercent: 30, powerMilliwatts: nil))
        #expect(percentOnly.value == "30%" && percentOnly.subtitle == "GPU 活跃度")
        // 无占用率 → 功率口径"~X mW 活跃度"（文案必须带活跃度，避免误读成百分比）
        let powerOnly = PerfPanelMapping.gpuTexts(GpuUsage(activePercent: nil, powerMilliwatts: 1840.4))
        #expect(powerOnly.value == "~1840 mW 活跃度")
        #expect(powerOnly.subtitle == "以功率估活跃度")
        // 双 nil → 整行隐藏
        #expect(PerfPanelMapping.gpuTexts(GpuUsage()).value == nil)
        #expect(PerfPanelMapping.gpuTexts(nil).value == nil)
        // 本分支契约占位：引擎 gpu 字段落地前 PerfSample.gpu 恒 nil（GPU 行隐藏，
        // 合并时以引擎侧为准——见 PerfPanelSupport.swift 合并纪律注记）
        let sample = PerfSample(cpu: nil, memory: nil, net: nil)
        #expect(sample.gpu == nil)
    }

    // MARK: - T-204 音频输入行

    @Test func audioInputRowHidesWhenNilAndMapsWhenPresent() async throws {
        let hidden = makeVM(audioInputProvider: nil)
        #expect(!hidden.showsAudioInputRow)
        hidden.panelDidAppear()
        #expect(!hidden.showsAudioInputRow)

        let noReading = makeVM(audioInputProvider: { nil })
        noReading.panelDidAppear()
        #expect(!noReading.showsAudioInputRow)  // 有 provider 无读数同样隐藏

        let shown = makeVM(audioInputProvider: {
            AudioInputStatus(level: 62, isMuted: true, deviceName: "MacBook 麦克风")
        })
        shown.panelDidAppear()
        #expect(shown.showsAudioInputRow)
        let texts = AudioInputPanelMapping.texts(shown.audioInput)
        #expect(texts?.deviceName == "MacBook 麦克风")
        #expect(texts?.levelText == "62%")
        #expect(texts?.isMuted == true)
        // 设备名空（数字输入设备常见）降级"麦克风"
        let unnamed = AudioInputPanelMapping.texts(AudioInputStatus(level: 0, isMuted: false, deviceName: ""))
        #expect(unnamed?.deviceName == "麦克风")
    }

    // MARK: - T-205 iDevice 占位行

    @Test func iDeviceRowCoversAllStates() async throws {
        // 态一：provider 未接线 → 整行隐藏
        let hidden = makeVM(mobileBatteryProvider: nil)
        #expect(!hidden.showsMobileBatteryRow)
        hidden.panelDidAppear()
        #expect(!hidden.showsMobileBatteryRow)

        // 态二：有设备 → 设备清单（Watch 无电量显示 "—"）
        let devices = [
            MobileBatteryDevice(name: "林的 iPhone", udid: "u-1", kind: .iPhone,
                                batteryPercent: 72, charging: true),
            MobileBatteryDevice(name: "Apple Watch", udid: "u-2", kind: .watch),
        ]
        let shown = makeVM(mobileBatteryProvider: { MobileBatterySummary(devices: devices) })
        shown.panelDidAppear()
        #expect(shown.showsMobileBatteryRow)
        #expect(shown.mobileBatterySummary?.devices.count == 2)
        #expect(MobileBatteryPanelDisplay.batteryText(72) == "72%")
        #expect(MobileBatteryPanelDisplay.batteryText(nil) == "—")
        #expect(MobileBatteryPanelDisplay.valueText(for: shown.mobileBatterySummary) == "2 台")
        #expect(MobileBatteryPanelDisplay.statusText(charging: true) == "充电中")
        #expect(MobileBatteryPanelDisplay.statusText(charging: nil) == "已连接")

        // 态三：summary nil 或空设备（含 helper unavailable 折叠）→ 同一引导文案
        let empty = makeVM(mobileBatteryProvider: { MobileBatterySummary(devices: []) })
        empty.panelDidAppear()
        #expect(empty.showsMobileBatteryRow)  // 分区仍在——占位引导是本职
        #expect(MobileBatteryPanelDisplay.subtitleText(for: empty.mobileBatterySummary)
                == MobileBatteryPanelDisplay.emptyGuidanceText)
        let unavailable = MobileBatterySummary(reading: MobileBatteryReading.unavailable)
        #expect(unavailable.devices.isEmpty)
        #expect(MobileBatteryPanelDisplay.subtitleText(for: unavailable)
                == MobileBatteryPanelDisplay.emptyGuidanceText)
        #expect(MobileBatteryPanelDisplay.subtitleText(for: nil)
                == MobileBatteryPanelDisplay.emptyGuidanceText)
        #expect(MobileBatteryPanelDisplay.valueText(for: nil) == "—")
        #expect(MobileBatteryPanelDisplay.emptyGuidanceText == "未检测到 Apple 设备（USB）")
    }

    // MARK: - T-207 历史查看页

    @Test func historyPushLoadsDailySeriesAndEvents() {
        let reader = MutableHistoryReader()
        reader.set(
            daily: [
                DailyMetricPoint(date: "2026-10-11", batteryCapacityPercent: 94),
                DailyMetricPoint(date: "2026-10-12", batteryCapacityPercent: 93),
            ],
            events: [
                EventRow(id: 1, at: "2026-10-12T08:00:00Z", kind: "wifiConnect", detail: "Home"),
                EventRow(id: 2, at: "2026-10-12T09:00:00Z", kind: "chargeStart", detail: nil),
            ]
        )
        let vm = makeVM(historyReader: reader)
        #expect(vm.showsHistoryEntryRow)
        #expect(vm.currentRoute == nil)

        vm.push(.history)
        #expect(vm.currentRoute == .history)
        #expect(vm.historyDaily.count == 2)
        #expect(vm.historyDaily.last?.batteryCapacityPercent == 93)
        #expect(vm.historyEvents.count == 2)
        // 未接读服务：入口不出现，push 也不读
        let unwired = makeVM(historyReader: nil)
        #expect(!unwired.showsHistoryEntryRow)
        unwired.push(.history)
        #expect(unwired.historyDaily.isEmpty)
    }

    @Test func historyEventFilterAndKindOptions() {
        let reader = MutableHistoryReader()
        reader.set(daily: [], events: [
            EventRow(id: 1, at: "2026-10-12T08:00:00Z", kind: "wifiConnect", detail: nil),
            EventRow(id: 2, at: "2026-10-12T09:00:00Z", kind: "chargeStart", detail: nil),
            EventRow(id: 3, at: "2026-10-13T08:00:00Z", kind: "wifiDisconnect", detail: "Home"),
        ])
        let vm = makeVM(historyReader: reader)
        vm.push(.history)
        #expect(vm.historyEventKindOptions == ["chargeStart", "wifiConnect", "wifiDisconnect"])
        // 无筛选：新在前（倒序）
        #expect(vm.filteredHistoryEvents.map(\.id) == [3, 2, 1])

        vm.setHistoryEventFilter("wifiConnect")
        #expect(vm.filteredHistoryEvents.map(\.id) == [1])

        vm.setHistoryEventFilter(nil)
        #expect(vm.filteredHistoryEvents.count == 3)

        // 筛选值在新数据里消失 → 刷新归零"全部"
        vm.setHistoryEventFilter("chargeStart")
        reader.set(daily: [], events: [
            EventRow(id: 4, at: "2026-10-13T09:00:00Z", kind: "wifiConnect", detail: nil),
        ])
        vm.refreshHistory()
        #expect(vm.historyEventFilter == nil)
        #expect(vm.filteredHistoryEvents.map(\.id) == [4])

        // 弹层关闭 → 筛选复位（transient 重开不记上次的筛选）
        vm.setHistoryEventFilter("wifiConnect")
        vm.panelWillDisappear()
        #expect(vm.historyEventFilter == nil)
    }

    @Test func historyChartPointsGeneration() {
        // 归一化坐标的浮点噪声（1-0.9 的双精度误差）按 ε 容差比较
        func close(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
            abs(lhs.x - rhs.x) < 0.0001 && abs(lhs.y - rhs.y) < 0.0001
        }
        func closeAll(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(close)
        }
        // 空数据 → 空点集
        #expect(HistoryChartMapping.capacityPoints([], size: CGSize(width: 100, height: 50)).isEmpty)
        // 零尺寸画布 → 空点集（不产生 NaN）
        #expect(HistoryChartMapping.capacityPoints(
            [DailyMetricPoint(date: "d", batteryCapacityPercent: 90)],
            size: CGSize(width: 0, height: 0)
        ).isEmpty)
        // 单点退化为 (0, y)——画一个点而不是空图
        let single = HistoryChartMapping.capacityPoints(
            [DailyMetricPoint(date: "d", batteryCapacityPercent: 90)],
            size: CGSize(width: 100, height: 50)
        )
        #expect(closeAll(single, [CGPoint(x: 0, y: 5)]))  // 90% → 50×(1-0.9)
        // 三点：x 均分（0/50/100），y 反转（容量高 → y 小）
        let points = HistoryChartMapping.capacityPoints(
            [
                DailyMetricPoint(date: "d1", batteryCapacityPercent: 100),
                DailyMetricPoint(date: "d2", batteryCapacityPercent: 50),
                DailyMetricPoint(date: "d3", batteryCapacityPercent: 0),
            ],
            size: CGSize(width: 100, height: 40)
        )
        #expect(closeAll(points, [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 20),
            CGPoint(x: 100, y: 40),
        ]))
        // 80% 参考线（BatteryHealthTier.attention 同门限）
        if let referenceY = HistoryChartMapping.referenceLineY(atPercent: 80, height: 40) {
            #expect(abs(referenceY - 8) < 0.0001)
        } else {
            Issue.record("80% 参考线不应缺测")
        }
        #expect(HistoryChartMapping.referenceLineY(atPercent: 80, height: 0) == nil)
    }

    @Test func historyCSVExportGoesThroughInjectedClosure() {
        let reader = MutableHistoryReader()
        reader.set(daily: [], events: [
            EventRow(id: 1, at: "2026-10-12T08:00:00Z", kind: "wifiConnect", detail: "Home"),
            EventRow(id: 2, at: "2026-10-13T09:00:00Z", kind: "chargeStart", detail: nil),
        ])
        let recorder = ExportRecorder()
        let vm = makeVM(historyReader: reader, historyExport: { recorder.handle($0, $1) })
        vm.push(.history)

        // 未接线先验：不伪装成功
        let unwired = makeVM(historyReader: reader)
        #expect(!unwired.isHistoryExportAvailable)
        #expect(unwired.exportHistoryCSV() == false)

        #expect(vm.isHistoryExportAvailable)
        #expect(vm.exportHistoryCSV() == true)
        #expect(vm.lastHistoryExportSucceeded == true)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.name == "statusbutler-history.csv")
        // 内容 = 当前筛选（新在前）经引擎 HistoryCSV 同一转义口径
        let expected = HistoryCSV.eventsToCSV([
            HistoryEvent(id: 2, at: "2026-10-13T09:00:00Z", kind: "chargeStart", detail: nil),
            HistoryEvent(id: 1, at: "2026-10-12T08:00:00Z", kind: "wifiConnect", detail: "Home"),
        ])
        #expect(recorder.calls.first?.content == expected)

        // 筛选后导出 = 所见即所得
        vm.setHistoryEventFilter("wifiConnect")
        _ = vm.exportHistoryCSV()
        let filteredCSV = HistoryCSV.eventsToCSV([
            HistoryEvent(id: 1, at: "2026-10-12T08:00:00Z", kind: "wifiConnect", detail: "Home"),
        ])
        #expect(recorder.calls.last?.content == filteredCSV)
    }

    @Test func historyEventFormattingNamesSymbolsAndTime() {
        #expect(HistoryEventFormatting.kindDisplayName("wifiConnect") == "Wi-Fi 接入")
        #expect(HistoryEventFormatting.kindDisplayName("chargeStop") == "结束充电")
        #expect(HistoryEventFormatting.kindDisplayName("pluginCustom") == "pluginCustom")  // 未知透传
        #expect(HistoryEventFormatting.symbolName(for: "wifiDisconnect") == "wifi")
        #expect(HistoryEventFormatting.symbolName(for: "chargeStart") == "bolt.fill")
        #expect(HistoryEventFormatting.symbolName(for: "mystery") == "circle")
        // 固定 UTC 时区钉死断言（默认参数是本地时区，只验解析成功形态）
        let utc = TimeZone(identifier: "UTC")!
        #expect(HistoryEventFormatting.timeText(iso: "2026-10-13T08:05:00Z", timeZone: utc) == "10-13 08:05")
        #expect(HistoryEventFormatting.timeText(iso: "not-a-date") == "not-a-date")
    }

    @Test func historyDatabaseAdaptsToReadingProtocol() throws {
        // 内存库全链路：HistoryDatabase → HistoryReading（UI 与 SQLite 类型解耦的适配层）
        let database = try HistoryDatabase(url: nil)
        try database.recordMetricDaily(date: "2026-10-11", batteryCapacityPercent: 95, cycleCount: 100)
        try database.recordMetricDaily(date: "2026-10-12", batteryCapacityPercent: 94, cycleCount: 101)
        try database.recordEvent(at: Date(timeIntervalSince1970: 1000), kind: "wifiConnect", detail: "A")
        try database.recordEvent(at: Date(timeIntervalSince1970: 2000), kind: "chargeStart", detail: nil)
        try database.recordEvent(at: Date(timeIntervalSince1970: 3000), kind: "wifiDisconnect", detail: "B")

        let reader: any HistoryReading = database
        #expect(reader.dailySeries() == [
            DailyMetricPoint(date: "2026-10-11", batteryCapacityPercent: 95),
            DailyMetricPoint(date: "2026-10-12", batteryCapacityPercent: 94),
        ])
        // limit 取最近的尾部（升序保持）
        let recent = reader.recentEvents(limit: 2)
        #expect(recent.map(\.kind) == ["chargeStart", "wifiDisconnect"])
        #expect(reader.recentEvents(limit: 10).count == 3)
    }

    // MARK: - T-210 Dock 屏幕坐标锚定（纯函数半场，无 WindowServer 依赖）

    @Test func screenAnchorFramePicksContainingScreenOrClampsFallback() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        // 点在第二块屏内 → 原样建 1×1 锚
        let inSecond = StatusPopoverController.anchorFrame(
            at: NSPoint(x: 2000, y: 500), screenFrames: screens, fallback: nil
        )
        #expect(inSecond.origin == NSPoint(x: 2000, y: 500))
        #expect(inSecond.width == 1 && inSecond.height == 1)
        // 点不在任何屏（陈旧坐标）→ 钳进 fallback 屏内
        let clamped = StatusPopoverController.anchorFrame(
            at: NSPoint(x: 5000, y: -50),
            screenFrames: screens,
            fallback: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(clamped.origin == NSPoint(x: 99, y: 0))
        // 无屏可用且无 fallback → .zero（调用方放弃弹出）
        #expect(StatusPopoverController.anchorFrame(
            at: NSPoint(x: 10, y: 10), screenFrames: [], fallback: nil
        ) == .zero)
    }
}

// MARK: - 窗口类用例（CI 无 WindowServer 跳过——能力守卫而非平台白名单）

extension PanelZoneP1Tests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func screenPointAnchoringShowsPopoverAbovePointAndTogglesClosed() {
        let vm = PanelViewModel(
            store: makeStore(),
            bluetooth: NilBluetoothMonitor(),
            thermal: NilThermalMonitor(),
            bypassPollInterval: .seconds(60)
        )
        let controller = StatusPopoverController(viewModel: vm)
        #expect(!controller.isShown)
        #expect(!controller.hasScreenAnchorWindow)

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let point = NSPoint(x: visibleFrame.midX, y: visibleFrame.minY + 24)

        controller.show(at: point)
        #expect(controller.isShown)
        #expect(controller.hasScreenAnchorWindow)  // 锚定窗在役
        // preferredEdge .maxY：弹层整体位于点位上方（Dock 在底缘的展开方向）
        if let contentFrame = controller.popover.contentViewController?.view.window?.frame {
            #expect(contentFrame.midY > point.y)
        }
        controller.show(at: point)  // 已显示时重复 show 幂等

        controller.toggle(at: point)  // 再切 = 收起（关闭动画依赖 run loop——泵着等落定）
        var closed = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if !controller.isShown {
                closed = true
                break
            }
        }
        #expect(closed)
        #expect(!controller.hasScreenAnchorWindow)  // 关闭即撤锚定窗，不留 1×1 隐形窗
    }
}
