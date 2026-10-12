import Testing
@testable import StatusButlerCore

// T-022: 音量映射纯函数（0.5→50 / nil / 静音优先 / 钳制 / 端点）+ 真机拉取冒烟
@Suite struct VolumeMonitorTests {
    @Test func halfVolumeMapsToFifty() {
        #expect(VolumeMonitor.state(averageVolume: 0.5, isMuted: false)
                == VolumeState(level: 50, isMuted: false))
    }

    @Test func nilVolumeMapsToZeroLevel() {
        #expect(VolumeMonitor.state(averageVolume: nil, isMuted: false)
                == VolumeState(level: 0, isMuted: false))
        // 音量读不到时静音位仍要如实透传（图标层靠它切斜杠符号）
        #expect(VolumeMonitor.state(averageVolume: nil, isMuted: true)
                == VolumeState(level: 0, isMuted: true))
    }

    @Test func muteTakesPrecedenceOverVolumeLevel() {
        #expect(VolumeMonitor.state(averageVolume: 0.8, isMuted: true)
                == VolumeState(level: 0, isMuted: true))
    }

    @Test func outOfRangeValuesAreClamped() {
        #expect(VolumeMonitor.state(averageVolume: 1.5, isMuted: false)
                == VolumeState(level: 100, isMuted: false))
        #expect(VolumeMonitor.state(averageVolume: -0.2, isMuted: false)
                == VolumeState(level: 0, isMuted: false))
    }

    @Test func exactEndpointsMapWithoutRoundingDrift() {
        #expect(VolumeMonitor.state(averageVolume: 0, isMuted: false)
                == VolumeState(level: 0, isMuted: false))
        #expect(VolumeMonitor.state(averageVolume: 1, isMuted: false)
                == VolumeState(level: 100, isMuted: false))
        #expect(VolumeMonitor.state(averageVolume: 0.435, isMuted: false)
                == VolumeState(level: 44, isMuted: false))
    }

    // 真机/headless 冒烟：默认设备存在与否都不得崩；level 恒在 0-100
    // （headless CI 有默认设备但读数可能全 0，不断言具体值）
    @Test func liveReadReturnsBoundedLevel() async {
        let monitor = VolumeMonitor()
        let state = await monitor.read()
        #expect((0...100).contains(state.level))
        let repeated = await monitor.read()
        #expect((0...100).contains(repeated.level))
    }
}
