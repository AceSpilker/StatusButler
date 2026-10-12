import CoreAudio
import Foundation

// T-022 音量监控（CoreAudio 拉取采样，替换 StaticVolumeMonitor）
// 只读默认输出设备的音量/静音；调节滑杆、设备切换、反馈音属 S6 后续任务。
//
// TODO(T-022b): 接 kAudioDevicePropertyVolumeScalar / kAudioDevicePropertyMute /
// kAudioHardwarePropertyDefaultOutputDevice 的属性 listener 做事件驱动推送，
// 替代轮询采样（B1 能效纪律"有人看才运行"）；本任务先补拉取通道。
//
// AudioObjectGetPropertyData 官方线程安全，无需像 CoreWLAN 那样加锁串行化；
// nonisolated async 本身运行在协作线程池，阻塞读取不占主线程。

public struct VolumeMonitor: VolumeMonitoring {
    public init() {}

    public func read() async -> VolumeState {
        // 默认输出设备 ID 要向系统对象查询，拿不到设备（无输出硬件）时
        // 静默降级为 level 0 / 未静音——headless CI 也有默认设备但值可能全 0，
        // 图标显示 0 即可，不把硬件异常上抛成崩溃或 unknown 态
        guard let deviceID = Self.defaultOutputDeviceID() else {
            return VolumeState(level: 0, isMuted: false)
        }
        let average = Self.averageOutputVolume(deviceID: deviceID)
        let muted = Self.isOutputMuted(deviceID: deviceID)
        return Self.state(averageVolume: average, isMuted: muted)
    }

    /// 音量均值 + 静音 → 快照状态。
    /// 静音优先：静音时用户实际听到的就是 0，直接归零 level，避免下游
    /// 出现"亮 3 个点 + 静音斜杠"的组合需要各自再抵消一次；isMuted 保留，
    /// 图标层靠它切 speaker.slash 符号。
    public static func state(averageVolume: Float32?, isMuted: Bool) -> VolumeState {
        guard !isMuted, let volume = averageVolume else {
            return VolumeState(level: 0, isMuted: isMuted)
        }
        // 属性读数理论在 0-1，防御性钳制：HAL 个别驱动会回报略越界值
        let clamped = min(max(volume, 0), 1)
        return VolumeState(level: Int((clamped * 100).rounded()), isMuted: false)
    }

    // MARK: - CoreAudio 读取（全失败容错）

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        // 状态错误或设备 ID 未知都按"无默认输出设备"处理
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func averageOutputVolume(deviceID: AudioObjectID) -> Float32? {
        // 任务口径取通道 1/2 均值；单声道设备没有通道 2 时退化为通道 1，
        // 两通道都读不到（设备不支持 VolumeScalar，如纯数字输出走独立音量）→ nil
        let left = channelVolume(deviceID: deviceID, channel: 1)
        let right = channelVolume(deviceID: deviceID, channel: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    private static func channelVolume(deviceID: AudioObjectID, channel: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func isOutputMuted(deviceID: AudioObjectID) -> Bool {
        // 部分设备只有通道级静音没有主静音：先主（element 0）后通道 1
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
            if status == noErr { return muted != 0 }
        }
        return false
    }
}
