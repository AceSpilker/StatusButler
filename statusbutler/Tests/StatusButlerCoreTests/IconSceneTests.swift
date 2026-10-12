import Testing
import AppKit
@testable import StatusButlerCore

// T-010: 快照 → 场景映射（纯函数）与渲染冒烟
@Suite struct IconSceneTests {
    private func snapshot(
        battery: BatteryState = .unavailable,
        link: NetworkLink = .offline,
        volume: VolumeState = VolumeState(level: 0, isMuted: false)
    ) -> StatusSnapshot {
        StatusSnapshot(battery: battery, link: link, volume: volume)
    }

    @Test func mappingBattery() {
        let scene = IconSceneState.from(snapshot(battery: .battery(level: 88, charging: true)))
        #expect(scene.batteryLevel == 88)
        #expect(scene.isCharging)
        #expect(IconSceneState.from(snapshot()).batteryLevel == nil)
    }

    @Test func mappingSignal() {
        #expect(IconSceneState.from(snapshot(link: .wifi(ssid: "Home", signalBars: 3))).signalBars == 3)
        #expect(IconSceneState.from(snapshot(link: .wired)).signalBars == 4)
        #expect(IconSceneState.from(snapshot(link: .offline)).signalBars == 0)
    }

    @Test func mappingVolumeDots() {
        #expect(IconSceneState.from(snapshot(volume: VolumeState(level: 100, isMuted: false))).volumeDots == 4)
        #expect(IconSceneState.from(snapshot(volume: VolumeState(level: 49, isMuted: false))).volumeDots == 2)
        #expect(IconSceneState.from(snapshot(volume: VolumeState(level: 80, isMuted: true))).volumeDots == 0)
        #expect(IconSceneState.from(snapshot(volume: VolumeState(level: 80, isMuted: true))).isMuted)
    }

    @Test func boundsClamp() {
        let scene = IconSceneState(batteryLevel: 50, isCharging: false, signalBars: 9, volumeDots: -3, isMuted: false)
        #expect(scene.signalBars == 4)
        #expect(scene.volumeDots == 0)
    }

    @Test func rendererProducesRequestedSize() {
        for size in [16.0, 18.0, 24.0] {
            let image = StatusIconRenderer.image(
                scene: IconSceneState.empty, pointSize: size, dark: false
            )
            #expect(Double(image.size.width) == size)
            #expect(Double(image.size.height) == size)
            if let rep = image.representations.first as? NSBitmapImageRep {
                #expect(rep.pixelsWide == Int(size * 2))
            }
            // 冒烟：能离屏渲染出位图
            #expect(image.tiffRepresentation != nil)
        }
    }
}
