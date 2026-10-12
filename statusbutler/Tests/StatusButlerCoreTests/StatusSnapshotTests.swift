import Testing
@testable import StatusButlerCore

// T-003: 快照相等性 = 渲染缓存 key 的根基（B1 铁律三）
@Suite struct StatusSnapshotTests {
    @Test func emptySnapshotIsConsistent() {
        #expect(StatusSnapshot.empty == StatusSnapshot.empty)
    }

    @Test func volumeChangeBreaksEquality() {
        var a = StatusSnapshot.empty
        var b = StatusSnapshot.empty
        b.volume.level = 50
        #expect(a != b)
        a.volume.level = 50
        #expect(a == b)
    }

    @Test func batteryStatesDistinguish() {
        #expect(BatteryState.battery(level: 80, charging: false) != BatteryState.battery(level: 80, charging: true))
        #expect(BatteryState.unavailable != BatteryState.battery(level: 0, charging: false))
    }

    @Test func networkLinksDistinguish() {
        #expect(NetworkLink.wifi(ssid: nil, signalBars: 3) != NetworkLink.wifi(ssid: "Home", signalBars: 3))
        #expect(NetworkLink.wired != NetworkLink.offline)
    }
}
