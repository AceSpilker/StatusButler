import Foundation
import Testing
@testable import StatusButlerCore

// A14-γ 接线测试：PerfEngine 引用计数采样、性能三槽位映射、注册表（含插件扫描）、
// ThermalSlot 缓存、WeatherFeed 节拍、WidgetFeed 节流写盘端到端、HistoryFeed 事件矩阵。
// 纪律：不碰真网/真 SMC 写路径——全部注入假实现；等待用轮询 + 宽限期（CI 慢机容忍）。

// MARK: - 测试基建

/// 轮询等待（宽限期默认 2s）：条件闭包只允许触碰线程安全盒子，防跨隔离竞争
func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// 线程安全计数采样器（CpuMonitoring 假实现）
final class CountingCpu: CpuMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let usage = CpuUsage(totalPercent: 33, perCore: [33])
    func read() async -> CpuUsage? {
        lock.withLock { calls += 1 }
        return usage
    }
    var callCount: Int { lock.withLock { calls } }
}

final class CountingMemory: MemoryMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func read() async -> MemoryUsage? {
        lock.withLock { calls += 1 }
        return MemoryUsage(
            totalBytes: 16_000_000_000, usedBytes: 8_000_000_000,
            wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000,
            freeBytes: 8_000_000_000, swapUsedBytes: 0
        )
    }
    var callCount: Int { lock.withLock { calls } }
}

final class CountingNet: NetRateMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func read() async -> NetRates? {
        lock.withLock { calls += 1 }
        return NetRates(bytesInPerSec: 2048, bytesOutPerSec: 1024)
    }
    var callCount: Int { lock.withLock { calls } }
}

/// 可变温度源（ThermalMonitoring 假实现，可随时改读数）
final class StubThermal: ThermalMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var reading: ThermalSnapshot?
    private let fail: Bool

    init(reading: ThermalSnapshot? = nil, fail: Bool = false) {
        self.reading = reading
        self.fail = fail
    }

    func set(celsius: Double) {
        lock.withLock {
            reading = ThermalSnapshot(
                fans: [],
                sensors: [SensorReading(key: "TC0P", name: nil, celsius: celsius)]
            )
        }
    }

    func read() async -> ThermalSnapshot? {
        lock.withLock {
            calls += 1
            return fail ? nil : reading
        }
    }

    var callCount: Int { lock.withLock { calls } }
}

/// 可注入时钟（非隔离可写）
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// 通知记录器（NotifierPostable 假实现：端到端断言 Darwin 通知确发）
final class RecordingNotifier: NotifierPostable, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [String] = []
    func post(_ name: String) { lock.withLock { posted.append(name) } }
    var names: [String] { lock.withLock { posted } }
}

/// 可变 Wi-Fi 源（HistoryFeed e2e 需要中途翻转链路）
final class MutableWiFi: WiFiMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var link: NetworkLink = .offline
    func set(_ newLink: NetworkLink) { lock.withLock { link = newLink } }
    func read() async -> NetworkLink { lock.withLock { link } }
}

/// 可变电池源（充电起止翻转用）
final class MutableBattery: BatteryMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: BatteryState = .unavailable
    func set(_ newState: BatteryState) { lock.withLock { state = newState } }
    func read() async -> BatteryState { lock.withLock { state } }
}

/// 假天气服务（计数 + 可设定结局）。默认成功帧的 fetchedAt 取远过去：
/// 让"缓存新鲜短路"类用例与"循环节拍"类用例互不牵连（新鲜度只由显式注入的 now 决定）
final class StubWeatherProvider: WeatherProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var result: Result<WeatherNow, WeatherError> = .success(
        WeatherNow(temperatureC: 21, weatherCode: 0, fetchedAt: Date(timeIntervalSince1970: 1_000_000_000))
    )
    func set(result: Result<WeatherNow, WeatherError>) { lock.withLock { self.result = result } }
    func fetch(latitude: Double, longitude: Double) async -> Result<WeatherNow, WeatherError> {
        lock.withLock { calls += 1 }
        return lock.withLock { result }
    }
    var callCount: Int { lock.withLock { calls } }
}

/// 假电池详情（metric_daily 注入源）
struct StubBatteryDetails: BatteryCapacityReading {
    let reading: (capacityPercent: Int, cycleCount: Int)?
    func read() async -> (capacityPercent: Int, cycleCount: Int)? { reading }
}

// MARK: - PerfEngine：引用计数与采样

@Suite(.serialized)
struct PerfEngineTests {

    @Test func refCountingRunsOnlyWithConsumers() async {
        let engine = PerfEngine(bus: PerfBus(), interval: .milliseconds(50))
        await engine.start("popover")
        #expect(await engine.isSampling)
        #expect(await engine.consumerCount == 1)

        await engine.start("slot")
        #expect(await engine.isSampling)
        #expect(await engine.consumerCount == 2)

        await engine.stop("popover")
        #expect(await engine.isSampling, "仍有消费者（槽位）时不得撤采样")

        await engine.stop("slot")
        #expect(!(await engine.isSampling))

        // 重复/未知 reason 的 stop 幂等且不误启
        await engine.stop("slot")
        await engine.stop("ghost")
        #expect(!(await engine.isSampling))
        #expect(await engine.consumerCount == 0)
    }

    @Test func duplicateReasonCountsOnce() async {
        let engine = PerfEngine(bus: PerfBus(), interval: .milliseconds(50))
        await engine.start("popover")
        await engine.start("popover")
        #expect(await engine.consumerCount == 1, "同一消费者重复 start 不得叠加计数")
        await engine.stop("popover")
        #expect(!(await engine.isSampling))
    }

    @Test func samplingLoopPublishesFramesAndStops() async {
        let bus = PerfBus()
        let cpu = CountingCpu()
        let memory = CountingMemory()
        let net = CountingNet()
        let engine = PerfEngine(
            cpu: cpu, memory: memory, net: net, bus: bus,
            interval: .milliseconds(20)
        )
        await engine.start("test")

        // 首帧到达总线（三域并读都出现）
        let gotFrame = await waitUntil(timeout: 3) { bus.sample?.cpu?.totalPercent == 33 }
        #expect(gotFrame, "采样循环应发布首帧")
        let netOk = await waitUntil(timeout: 3) { bus.sample?.net?.bytesInPerSec == 2048 }
        #expect(netOk)
        let memOk = await waitUntil(timeout: 3) { bus.sample?.memory?.totalBytes == 16_000_000_000 }
        #expect(memOk)
        #expect(cpu.callCount >= 1)

        // 连续节拍确实在跑（计数增长）
        let midCount = cpu.callCount
        let grew = await waitUntil(timeout: 2) { cpu.callCount >= midCount + 2 }
        #expect(grew, "持续有消费者时应持续采样")

        // 撤最后一个消费者后采样停止
        await engine.stop("test")
        let stoppedAt = cpu.callCount
        try? await Task.sleep(for: .milliseconds(200))
        #expect(cpu.callCount == stoppedAt, "计数归零后不得再采样（有人看才采样）")
    }

    @Test func sampleOncePublishesPartialFrameOnDomainFailure() async {
        let bus = PerfBus()
        let engine = PerfEngine(
            cpu: CountingCpu(), memory: CountingMemory(), net: CountingNet(),
            bus: bus, interval: .seconds(1)
        )
        await engine.sampleOnce()
        #expect(bus.sample != nil)
        #expect(bus.sample?.cpu != nil)
    }
}

// MARK: - 性能三槽位映射（纯函数 + 总线读）

@Suite struct PerfSlotTests {
    private var snapshot: StatusSnapshot { .empty }

    @Test func netSpeedTextIsHumanReadable() {
        #expect(NetSpeedSlot.speedText(bytesPerSec: 0) == "0 KB/s")
        #expect(NetSpeedSlot.speedText(bytesPerSec: 512) == "512 B/s")
        #expect(NetSpeedSlot.speedText(bytesPerSec: 5 * 1024) == "5.0 KB/s")
        #expect(NetSpeedSlot.speedText(bytesPerSec: 50 * 1024) == "50 KB/s")
        #expect(NetSpeedSlot.speedText(bytesPerSec: 1.5 * 1024 * 1024) == "1.5 MB/s")
        #expect(NetSpeedSlot.speedText(bytesPerSec: 150 * 1024 * 1024) == "150 MB/s")
    }

    @Test func netSpeedLevelBuckets() {
        #expect(NetSpeedSlot.level(forBytesPerSec: 100) == 0)
        #expect(NetSpeedSlot.level(forBytesPerSec: 50 * 1024) == 1)
        #expect(NetSpeedSlot.level(forBytesPerSec: 500 * 1024) == 2)
        #expect(NetSpeedSlot.level(forBytesPerSec: 5 * 1024 * 1024) == 3)
        #expect(NetSpeedSlot.level(forBytesPerSec: 20 * 1024 * 1024) == 4)
    }

    @Test func netSpeedSlotReadsBusAndDegradesToNil() {
        let bus = PerfBus()
        #expect(NetSpeedSlot(bus: bus).scene(snapshot: snapshot, now: Date()) == nil, "无帧 → 占位语义 nil")

        bus.send(PerfSample(cpu: nil, memory: nil, net: NetRates(bytesInPerSec: 3 * 1024 * 1024, bytesOutPerSec: 0)))
        let scene = NetSpeedSlot(bus: bus).scene(snapshot: snapshot, now: Date())
        #expect(scene?.valueText == "3.0 MB/s")
        #expect(scene?.level == 3)
        #expect(scene?.isWarning == false)
    }

    @Test func cpuUsageSlotMapping() {
        let scene = CpuUsageSlot.scene(forTotalPercent: 42.4)
        #expect(scene.valueText == "42%")
        #expect(scene.level == 1)
        #expect(scene.isWarning == false)

        let hot = CpuUsageSlot.scene(forTotalPercent: 95)
        #expect(hot.valueText == "95%")
        #expect(hot.isWarning == true)

        #expect(CpuUsageSlot(bus: PerfBus()).scene(snapshot: snapshot, now: Date()) == nil, "无帧 → nil")

        let bus = PerfBus()
        bus.send(PerfSample(cpu: CpuUsage(totalPercent: 77, perCore: [77]), memory: nil, net: nil))
        #expect(CpuUsageSlot(bus: bus).scene(snapshot: snapshot, now: Date())?.valueText == "77%")
    }

    @Test func memoryPressureSlotTiers() {
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.45).level == 1)
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.55).level == 2)
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.75).level == 3)
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.86).level == 4)
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.92).isWarning == true)
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.75).valueText == "75%")
        #expect(MemoryPressureSlot.scene(forUsedRatio: 0.89).isWarning == false, "警示线 0.9，0.89 不亮")

        #expect(MemoryPressureSlot(bus: PerfBus()).scene(snapshot: snapshot, now: Date()) == nil, "无帧 → nil")
    }
}

// MARK: - 温度槽位：缓存与降级

@Suite struct ThermalSlotTests {
    private var snapshot: StatusSnapshot { .empty }

    @Test func cachesWithinSixtySeconds() async {
        let thermal = StubThermal()
        thermal.set(celsius: 52.3)
        let slot = ThermalSlot(thermal: thermal)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // 冷缓存：立即返回 nil（后台读异步进行）
        #expect(slot.scene(snapshot: snapshot, now: t0) == nil)
        let filled = await waitUntil(timeout: 3) {
            slot.scene(snapshot: snapshot, now: t0.addingTimeInterval(10)) != nil
        }
        #expect(filled, "后台读完成后缓存应有值")

        let scene = slot.scene(snapshot: snapshot, now: t0.addingTimeInterval(20))
        #expect(scene?.valueText == "52°")
        #expect(scene?.level == 2)
        #expect(scene?.isWarning == false)

        // 60s 缓存兜底：窗口内重复拉取不再读 SMC
        _ = slot.scene(snapshot: snapshot, now: t0.addingTimeInterval(30))
        #expect(thermal.callCount == 1, "60s 内多次拉取只允许一次真实读取")
    }

    @Test func nilReadingDegradesToPlaceholder() async {
        let thermal = StubThermal(fail: true)
        let slot = ThermalSlot(thermal: thermal)
        let t0 = Date()

        #expect(slot.scene(snapshot: snapshot, now: t0) == nil)
        // 等后台读确实执行过（计数到 1）后再断言降级，避免假阳性
        let read = await waitUntil(timeout: 3) { thermal.callCount >= 1 }
        #expect(read)
        #expect(slot.scene(snapshot: snapshot, now: t0.addingTimeInterval(5)) == nil, "SMC 不可用 → 槽位 nil 降级")
    }

    @Test func sceneMappingTiers() {
        #expect(ThermalSlot.scene(forCelsius: 35).level == 1)
        #expect(ThermalSlot.scene(forCelsius: 55).level == 2)
        #expect(ThermalSlot.scene(forCelsius: 75).level == 3)
        #expect(ThermalSlot.scene(forCelsius: 82).level == 4)
        #expect(ThermalSlot.scene(forCelsius: 93).isWarning == true)
        #expect(ThermalSlot.scene(forCelsius: 45).valueText == "45°")
    }
}

// MARK: - 天气槽位与调度

@Suite struct WeatherFeedTests {

    @Test func weatherSlotReadsCache() {
        let cache = WeatherCache()
        #expect(WeatherSlot(cache: cache).scene(snapshot: .empty, now: Date()) == nil, "空缓存 → nil 降级")

        cache.store(WeatherNow(temperatureC: 23.4, weatherCode: 1, fetchedAt: Date()))
        let scene = WeatherSlot(cache: cache).scene(snapshot: .empty, now: Date())
        #expect(scene?.symbol == "cloud.sun.fill")
        #expect(scene?.valueText == "23°")
        #expect(scene?.isWarning == false)
    }

    @MainActor @Test func tickFetchesAndStoresWhenVisible() async {
        let provider = StubWeatherProvider()
        let cache = WeatherCache()
        let feed = WeatherFeed(
            provider: provider, cache: cache,
            location: { (latitude: 31.2304, longitude: 121.4737) },
            isVisible: { true }
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await feed.tick(now: now)

        #expect(provider.callCount == 1)
        #expect(cache.lastKnown()?.temperatureC == 21)
    }

    @MainActor @Test func tickSkipsWhenInvisible() async {
        let provider = StubWeatherProvider()
        let feed = WeatherFeed(
            provider: provider, cache: WeatherCache(),
            location: { (31.2, 121.5) },
            isVisible: { false }
        )
        await feed.tick()
        #expect(provider.callCount == 0, "不可见不得取数（有人看才采样）")
    }

    @MainActor @Test func tickSkipsWhenCacheFresh() async {
        let provider = StubWeatherProvider()
        let cache = WeatherCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store(WeatherNow(temperatureC: 20, weatherCode: 0, fetchedAt: now))
        let feed = WeatherFeed(
            provider: provider, cache: cache,
            location: { (31.2, 121.5) }, isVisible: { true }
        )
        await feed.tick(now: now.addingTimeInterval(60))
        #expect(provider.callCount == 0, "新鲜期内节拍白跑 = 违反能效铁律")
    }

    @MainActor @Test func failureKeepsOldValueSilently() async {
        let provider = StubWeatherProvider()
        let cache = WeatherCache()
        // fetchedAt 距注入 now 约 28 小时：确保已过期（才轮到取数失败路径）
        let original = WeatherNow(temperatureC: 19, weatherCode: 2, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        cache.store(original)
        provider.set(result: .failure(.network("断网")))
        let feed = WeatherFeed(
            provider: provider, cache: cache,
            location: { (31.2, 121.5) }, isVisible: { true }
        )
        await feed.tick(now: Date(timeIntervalSince1970: 1_700_100_000))
        #expect(provider.callCount == 1)
        #expect(cache.lastKnown() == original, "失败静默留旧值（quietFailureText 语义）")
    }

    @MainActor @Test func noLocationShortCircuits() async {
        let provider = StubWeatherProvider()
        let feed = WeatherFeed(provider: provider, cache: WeatherCache(), location: { nil })
        await feed.tick()
        #expect(provider.callCount == 0)
    }

    @MainActor @Test func scheduledLoopTicksAndStops() async throws {
        let provider = StubWeatherProvider()
        let feed = WeatherFeed(
            provider: provider, cache: WeatherCache(),
            location: { (31.2, 121.5) }, isVisible: { true },
            interval: 0.05
        )
        feed.start()
        #expect(feed.isRunning)
        let ticked = await waitUntil(timeout: 3) { provider.callCount >= 2 }
        #expect(ticked, "调度循环应按注入节拍取数")
        feed.stop()
        #expect(!feed.isRunning)
        let stoppedAt = provider.callCount
        try? await Task.sleep(for: .milliseconds(200))
        #expect(provider.callCount == stoppedAt, "stop 后不得继续取数")
    }
}

// MARK: - 注册表：真源替换 + 插件扫描并入

@Suite struct SlotRegistryWiringTests {

    @Test func builtinIDsCoverRealSources() {
        let ids = Set(SlotRegistry.builtin.keys)
        let expected: Set<String> = [
            "volume", "clock", "batteryPercent", "diskFree",
            "netSpeed", "cpuUsage", "memoryPressure", "temperature", "weather",
            "calendarCountdown",
        ]
        #expect(expected.isSubset(of: ids))
        // 真源就位：性能三源不再是占位
        #expect(SlotRegistry.builtin["netSpeed"] is NetSpeedSlot)
        #expect(SlotRegistry.builtin["cpuUsage"] is CpuUsageSlot)
        #expect(SlotRegistry.builtin["memoryPressure"] is MemoryPressureSlot)
        #expect(SlotRegistry.builtin["temperature"] is ThermalSlot)
        #expect(SlotRegistry.builtin["weather"] is WeatherSlot)
    }

    @Test func scannedPluginsJoinRegistryWithPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sb-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pluginDir = root.appending(path: "dailyword", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest = """
        {"id":"dailyword","name":"每日一词","interpreter":"/bin/sh","refreshHintSeconds":600}
        """
        try manifest.data(using: .utf8)!.write(to: pluginDir.appending(path: "manifest.json"))
        try "#!/bin/sh\n".data(using: .utf8)!.write(to: pluginDir.appending(path: "script.sh"))
        defer { try? FileManager.default.removeItem(at: root) }

        let map = SlotRegistry.slots(pluginRoot: root)
        #expect(map["plugin:dailyword"] is PluginSlot, "扫描产物以 plugin: 前缀并入注册表")
        #expect(map["volume"] is VolumeSlot, "插件注入不影响内置源")
    }

    @Test func scanFailureYieldsEmptyPluginTable() {
        let bogus = URL(fileURLWithPath: "/nonexistent/statusbutler/plugins-\(UUID().uuidString)")
        let map = SlotRegistry.slots(pluginRoot: bogus)
        #expect(map.keys.allSatisfy { !$0.hasPrefix("plugin:") }, "扫描失败/目录缺失 → 插件表为空")
        #expect(map["clock"] is ClockSlot)
    }
}

// MARK: - 小组件快照写入者：节流三元组端到端

@Suite struct WidgetFeedTests {

    @MainActor private func makeStore(
        battery: any BatteryMonitoring = StaticBatteryMonitor(.battery(level: 50, charging: false)),
        wifi: any WiFiMonitoring = StaticWiFiMonitor(.wifi(ssid: "H", signalBars: 4))
    ) -> SystemStatusStore {
        SystemStatusStore(
            battery: battery, wifi: wifi,
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
    }

    @MainActor @Test func writesThrottlesAndNotifies() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sb-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let notifier = RecordingNotifier()
        let writer = WidgetSnapshotWriter(directory: dir, notifier: notifier)
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let thermal = StubThermal()
        thermal.set(celsius: 45)
        let store = makeStore()
        await store.refresh()  // 先备好真实快照，再订阅——首写即含三合一数据

        let feed = WidgetFeedCoordinator(
            store: store, thermal: thermal, perf: PerfBus(),
            writer: writer, thermalReadInterval: .seconds(60),
            now: { clock.now }
        )
        feed.start()
        #expect(feed.isRunning)

        // 首写必发：组件从"无数据"到"有数据"
        let first = await waitUntil { writer.read() != nil }
        #expect(first)
        #expect(notifier.names.count == 1)
        #expect(notifier.names.first == WidgetSnapshotWriter.notificationName)
        #expect(writer.read()?.battery == .battery(level: 50, charging: false))

        // 温度 nil→45：可展示变化 → 第二写
        await feed.readThermalOnce()
        #expect(notifier.names.count == 2)
        #expect(writer.read()?.maxCelsius == 45)

        // 45→45.5（<2°）且同秒：三元组全不满足 → 不写
        thermal.set(celsius: 45.5)
        await feed.readThermalOnce()
        #expect(notifier.names.count == 2, "低幅度变化不得烧刷新预算")

        // 距上次 ≥30s：数值纹丝不动也要发（组件不能冻结在旧时刻）
        clock.now = clock.now.addingTimeInterval(31)
        thermal.set(celsius: 45.9)
        await feed.readThermalOnce()
        #expect(notifier.names.count == 3)
        #expect(writer.read()?.maxCelsius == 45.9)
        #expect(writer.read()?.fanAverageRPM == nil, "无风扇数据不编造 0")

        feed.stop()
        #expect(!feed.isRunning)
    }

    @MainActor @Test func netRatesFrameLandsInSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sb-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let notifier = RecordingNotifier()
        let writer = WidgetSnapshotWriter(directory: dir, notifier: notifier)
        let clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let bus = PerfBus()
        let store = makeStore()
        await store.refresh()
        let feed = WidgetFeedCoordinator(
            store: store, thermal: StubThermal(fail: true), perf: bus,
            writer: writer, thermalReadInterval: .seconds(60),
            now: { clock.now }
        )
        feed.start()
        _ = await waitUntil { writer.read() != nil }

        clock.now = clock.now.addingTimeInterval(31)  // 放行 30s 门槛
        bus.send(PerfSample(
            cpu: nil, memory: nil,
            net: NetRates(bytesInPerSec: 4096, bytesOutPerSec: 2048)
        ))
        let landed = await waitUntil { writer.read()?.netBytesPerSec != nil }
        #expect(landed, "网速帧应汇入快照")
        #expect(writer.read()?.netBytesPerSec?.in == 4096)
        #expect(writer.read()?.netBytesPerSec?.out == 2048)
        feed.stop()
    }

    @Test func fanAverageIgnoresEmptyAndRounds() {
        #expect(WidgetFeedCoordinator.fanAverageRPM(fans: []) == nil)
        let fans = [
            FanReading(id: 0, minRPM: 1000, maxRPM: 5000, currentRPM: 1000),
            FanReading(id: 1, minRPM: 1000, maxRPM: 5000, currentRPM: 2000),
        ]
        #expect(WidgetFeedCoordinator.fanAverageRPM(fans: fans) == 1500)
        // .5 进位（rounded 半远离零）
        let half = [
            FanReading(id: 0, minRPM: 1000, maxRPM: 5000, currentRPM: 1000),
            FanReading(id: 1, minRPM: 1000, maxRPM: 5000, currentRPM: 2001),
        ]
        #expect(WidgetFeedCoordinator.fanAverageRPM(fans: half) == 1501)
    }
}

// MARK: - 历史落盘：事件矩阵 + 端到端 + 保留策略

@Suite struct HistoryFeedTests {

    private func snap(
        link: NetworkLink = .wifi(ssid: "H", signalBars: 4),
        battery: BatteryState = .battery(level: 50, charging: false)
    ) -> StatusSnapshot {
        StatusSnapshot(battery: battery, link: link, volume: VolumeState(level: 50, isMuted: false))
    }

    @Test func transitionMatrixRecordsOnlyFlips() {
        let kindsOf: (StatusSnapshot, StatusSnapshot) -> [String] = { old, new in
            HistoryFeed.transitionEvents(from: old, to: new).map(\.kind)
        }

        // Wi-Fi 连断
        #expect(kindsOf(snap(link: .offline), snap(link: .wifi(ssid: "Home", signalBars: 3))) == ["wifiConnect"])
        #expect(kindsOf(snap(link: .wifi(ssid: "Home", signalBars: 3)), snap(link: .offline)) == ["wifiDisconnect"])
        #expect(kindsOf(snap(link: .wifi(ssid: "A", signalBars: 3)), snap(link: .wifi(ssid: "B", signalBars: 3))) == ["wifiConnect"], "换网（漫游/切网）记一次接入")
        #expect(kindsOf(snap(), snap()) == [], "完全相同 → 零事件（翻转才记）")

        // 有线插拔 + 与 Wi-Fi 并存
        #expect(kindsOf(snap(link: .offline), snap(link: .wired)) == ["wiredConnect"])
        #expect(kindsOf(snap(link: .wired), snap(link: .offline)) == ["wiredDisconnect"])
        #expect(kindsOf(snap(link: .wifi(ssid: "A", signalBars: 3)), snap(link: .wired)) == ["wifiDisconnect", "wiredConnect"])

        // 充电起止：charging 翻转才记
        #expect(kindsOf(snap(battery: .battery(level: 50, charging: false)), snap(battery: .battery(level: 55, charging: false))) == [])
        #expect(kindsOf(snap(battery: .battery(level: 50, charging: false)), snap(battery: .battery(level: 60, charging: true))) == ["chargeStart"])
        #expect(kindsOf(snap(battery: .battery(level: 60, charging: true)), snap(battery: .battery(level: 95, charging: true))) == [], "充电中电量波动不记")
        #expect(kindsOf(snap(battery: .battery(level: 95, charging: true)), snap(battery: .battery(level: 80, charging: false))) == ["chargeStop"])
        #expect(kindsOf(snap(battery: .unavailable), snap(battery: .battery(level: 50, charging: true))) == [], "unavailable 无基线不记")
    }

    @Test func transitionDetailsCarrySSID() {
        let events = HistoryFeed.transitionEvents(
            from: snap(link: .offline),
            to: snap(link: .wifi(ssid: "Cafe", signalBars: 2))
        )
        #expect(events.first?.detail == "Cafe")
    }

    @MainActor @Test func endToEndRecordsEventsToSQLite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sb-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let wifi = MutableWiFi()
        let battery = MutableBattery()
        let store = SystemStatusStore(
            battery: battery, wifi: wifi,
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
        let feed = HistoryFeed(store: store, databaseURL: url, details: nil)
        feed.start()

        wifi.set(.wifi(ssid: "Home", signalBars: 4))
        battery.set(.battery(level: 50, charging: false))
        await store.refresh()  // 基线 empty(off/unavail) → wifi/电池：记 wifiConnect（充电无基线不记）

        wifi.set(.offline)
        battery.set(.battery(level: 50, charging: true))  // 充电 false→true 翻转：另记 chargeStart
        await store.refresh()  // wifi → offline：记 wifiDisconnect

        let db = try #require(feed.database)
        let events = try db.listEvents()
        #expect(events.map(\.kind) == ["wifiConnect", "wifiDisconnect", "chargeStart"])
        #expect(events.first?.detail == "Home")

        feed.stop()
    }

    @MainActor @Test func retentionPolicyRunsOnStart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sb-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.unavailable),
            wifi: StaticWiFiMonitor(.offline),
            volume: StaticVolumeMonitor(VolumeState(level: 0, isMuted: false))
        )
        let feed = HistoryFeed(store: store, databaseURL: url, details: nil)
        let db = try #require(feed.database)

        // 预埋：40 天前事件（应被 30 天保留策略清掉）+ 今天事件（保留）
        try db.recordEvent(at: Date().addingTimeInterval(-40 * 86400), kind: "wifiDisconnect", detail: "ancient")
        try db.recordEvent(at: Date(), kind: "wifiConnect", detail: "today")

        feed.start()  // 启动即 applyRetentionPolicy

        let remaining = try db.listEvents()
        #expect(remaining.count == 1)
        #expect(remaining.first?.detail == "today")
        feed.stop()
    }

    @MainActor @Test func dailyMetricRecordsOncePerDay() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sb-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.battery(level: 88, charging: false)),
            wifi: StaticWiFiMonitor(.offline),
            volume: StaticVolumeMonitor(VolumeState(level: 50, isMuted: false))
        )
        let feed = HistoryFeed(
            store: store, databaseURL: url,
            details: StubBatteryDetails(reading: (capacityPercent: 87, cycleCount: 42))
        )
        let db = try #require(feed.database)

        feed.process(store.snapshot)
        let recorded = await waitUntil(timeout: 3) { (try? db.listMetricDaily().isEmpty) == false }
        #expect(recorded, "换日首帧应落 metric_daily")

        feed.process(store.snapshot)  // 同日第二帧：REPLACE 不增行
        try? await Task.sleep(for: .milliseconds(100))
        let rows = try db.listMetricDaily()
        #expect(rows.count == 1)
        #expect(rows.first?.batteryCapacityPercent == 87)
        #expect(rows.first?.cycleCount == 42)
        #expect(rows.first?.date == HistoryDatabase.dayKey(Date()))
        feed.stop()
    }
}
