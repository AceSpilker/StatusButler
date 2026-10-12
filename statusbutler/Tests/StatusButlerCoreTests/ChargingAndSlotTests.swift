import Testing
import Foundation
@testable import StatusButlerCore

// T-013/T-014: 充电相位与门控 + 槽位源
@Suite struct ChargingEffectTests {
    @Test func phaseBounds() {
        #expect(ChargingEffectPhase.glow(elapsed: .seconds(0)) == 0)
        let mid = ChargingEffectPhase.glow(elapsed: .seconds(1))
        #expect(mid > 0.98 && mid < 1.02)
        #expect(ChargingEffectPhase.glow(elapsed: .seconds(2)) < 0.01)
    }

    @Test func policyGating() {
        let base = ChargingEffectPolicy(enabled: true, reduceMotion: false, displayAsleep: false, isCharging: true)
        #expect(base.isActive)
        #expect(!ChargingEffectPolicy(enabled: false, reduceMotion: false, displayAsleep: false, isCharging: true).isActive)
        #expect(!ChargingEffectPolicy(enabled: true, reduceMotion: true, displayAsleep: false, isCharging: true).isActive)
        #expect(!ChargingEffectPolicy(enabled: true, reduceMotion: false, displayAsleep: true, isCharging: true).isActive)
        #expect(!ChargingEffectPolicy(enabled: true, reduceMotion: false, displayAsleep: false, isCharging: false).isActive)
    }
}

@Suite struct SlotSystemTests {
    private var snapshot: StatusSnapshot {
        StatusSnapshot(
            battery: .battery(level: 66, charging: false),
            link: .wifi(ssid: "H", signalBars: 4),
            volume: VolumeState(level: 50, isMuted: false)
        )
    }

    @Test func volumeSlot() {
        let scene = SlotComposer(selectedID: "volume").footer(snapshot: snapshot)
        #expect(scene?.level == 2)
        #expect(scene?.isWarning == false)
    }

    @Test func clockSlotFormats() {
        let scene = SlotComposer(selectedID: "clock").footer(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(scene?.valueText?.count == 5)  // HH:mm
    }

    @Test func batterySlotWarnsLow() {
        var low = snapshot
        low.battery = .battery(level: 12, charging: false)
        let scene = SlotComposer(selectedID: "batteryPercent").footer(snapshot: low)
        #expect(scene?.valueText == "12%")
        #expect(scene?.isWarning == true)
    }

    @Test func pendingSourcesReturnNil() {
        for id in ["netSpeed", "cpuUsage", "temperature"] {
            #expect(SlotComposer(selectedID: id).footer(snapshot: snapshot) == nil)
        }
    }

    @Test func unknownSlotFallsBackToNil() {
        #expect(SlotComposer(selectedID: "nope").footer(snapshot: snapshot) == nil)
    }
}
