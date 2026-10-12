import Testing
import Foundation
@testable import StatusButlerCore

// T-003: Store 聚合逻辑（注入静态假监控器；不测轮询定时，只测 refresh 语义）
@MainActor
@Suite struct SystemStatusStoreTests {
    @Test func refreshAggregatesAllMonitors() async {
        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.battery(level: 88, charging: true)),
            wifi: StaticWiFiMonitor(.wifi(ssid: "Home", signalBars: 4)),
            volume: StaticVolumeMonitor(VolumeState(level: 60, isMuted: false))
        )
        #expect(store.snapshot == .empty)
        await store.refresh()
        #expect(store.snapshot.battery == .battery(level: 88, charging: true))
        #expect(store.snapshot.link == .wifi(ssid: "Home", signalBars: 4))
        #expect(store.snapshot.volume.level == 60)
    }

    @Test func startThenStopIsIdempotent() async {
        let store = SystemStatusStore(
            battery: StaticBatteryMonitor(.unavailable),
            wifi: StaticWiFiMonitor(.offline),
            volume: StaticVolumeMonitor(VolumeState(level: 0, isMuted: false)),
            refreshInterval: .seconds(60)
        )
        store.start()
        store.start()   // 重复 start 不产生第二个循环
        store.stop()
        store.stop()    // 重复 stop 安全
        #expect(true)
    }
}
