import Testing

@testable import StatusButlerCore

// A14-δ 音频输入映射：与 VolumeMonitorTests 同一口径（静音优先/nil/钳制/端点/
// 防御性形态）+ 设备名折叠 + live 冒烟。CoreAudio 读取全失败容错不进断言细节。
@Suite struct AudioInputMonitorTests {

    @Test func halfInputVolumeMapsToFifty() {
        #expect(AudioInputMonitor.status(averageVolume: 0.5, isMuted: false, deviceName: "MacBook 麦克风")
                == AudioInputStatus(level: 50, isMuted: false, deviceName: "MacBook 麦克风"))
    }

    @Test func nilVolumeMapsToZeroLevelAndPassesMuteThrough() {
        // 增益读不到（纯数字输入无模拟增益级）：level 归 0，静音位如实透传
        #expect(AudioInputMonitor.status(averageVolume: nil, isMuted: false, deviceName: "USB 话筒")
                == AudioInputStatus(level: 0, isMuted: false, deviceName: "USB 话筒"))
        #expect(AudioInputMonitor.status(averageVolume: nil, isMuted: true, deviceName: "USB 话筒")
                == AudioInputStatus(level: 0, isMuted: true, deviceName: "USB 话筒"))
    }

    @Test func muteTakesPrecedenceOverVolumeLevel() {
        #expect(AudioInputMonitor.status(averageVolume: 0.8, isMuted: true, deviceName: "x")
                == AudioInputStatus(level: 0, isMuted: true, deviceName: "x"))
    }

    @Test func outOfRangeValuesAreClamped() {
        #expect(AudioInputMonitor.status(averageVolume: 1.5, isMuted: false, deviceName: "x").level == 100)
        #expect(AudioInputMonitor.status(averageVolume: -0.2, isMuted: false, deviceName: "x").level == 0)
    }

    @Test func exactEndpointsAndThirdQuarterMapWithoutRoundingDrift() {
        #expect(AudioInputMonitor.status(averageVolume: 0, isMuted: false, deviceName: "x").level == 0)
        #expect(AudioInputMonitor.status(averageVolume: 1, isMuted: false, deviceName: "x").level == 100)
        #expect(AudioInputMonitor.status(averageVolume: 0.435, isMuted: false, deviceName: "x").level == 44)
    }

    @Test func deviceNameFoldsToEmptyWhenMissingOrBlank() {
        // 设备名只服务面板（旁路属性）：nil/空白折叠空串，"未命名"文案归展示层
        #expect(AudioInputMonitor.status(averageVolume: 0.5, isMuted: false, deviceName: nil)
                == AudioInputStatus(level: 50, isMuted: false, deviceName: ""))
        #expect(AudioInputMonitor.status(averageVolume: 0.5, isMuted: false, deviceName: "  \n ")
                == AudioInputStatus(level: 50, isMuted: false, deviceName: ""))
    }

    // 真机/headless 冒烟：无输入硬件/默认设备读不到都不得崩，level 恒在 0-100
    @Test func liveReadReturnsBoundedLevel() async {
        let monitor = AudioInputMonitor()
        let status = await monitor.read()
        #expect((0...100).contains(status.level))
        let repeated = await monitor.read()
        #expect((0...100).contains(repeated.level))
    }
}
