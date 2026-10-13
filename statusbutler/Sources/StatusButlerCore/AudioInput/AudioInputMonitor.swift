import CoreAudio
import Foundation

// A14-δ 音频输入监控（A2·S6 缺口）：默认输入设备的话筒音量/静音/设备名，
// 手法与 Monitoring/VolumeMonitor.swift 同源（拉取式采样 + 全失败静默降级），
// 只是把 scope 从 output 换成 input、默认设备查询换成 DefaultInputDevice。
// 采样纪律（能效铁律"有人看才运行"）归接线层——本类型只是取数源。

/// 输入侧快照：level 0-100 / 静音位 / 设备名（读不到折叠空串，"未命名"文案归展示层）
public struct AudioInputStatus: Equatable, Sendable {
    public let level: Int
    public let isMuted: Bool
    public let deviceName: String

    public init(level: Int, isMuted: Bool, deviceName: String) {
        self.level = level
        self.isMuted = isMuted
        self.deviceName = deviceName
    }
}

/// 输入监控协议（`-ing` 后缀惯例，面板/测试注入假实现）
public protocol AudioInputMonitoring: Sendable {
    func read() async -> AudioInputStatus
}

public struct AudioInputMonitor: AudioInputMonitoring {
    public init() {}

    public func read() async -> AudioInputStatus {
        await Task.detached(priority: .utility) { Self.snapshot() }.value
    }

    /// 纯映射：与 VolumeMonitor.state 同口径——静音优先归零 level（下游不再各自
    /// 抵消一次），isMuted 透传给图标层切符号；音量理论在 0-1，防御性钳制。
    /// deviceName 仅服务面板（旁路属性），nil 折叠空串。
    public static func status(
        averageVolume: Float32?,
        isMuted: Bool,
        deviceName: String?
    ) -> AudioInputStatus {
        let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !isMuted, let volume = averageVolume else {
            return AudioInputStatus(level: 0, isMuted: isMuted, deviceName: name)
        }
        let clamped = min(max(volume, 0), 1)
        return AudioInputStatus(
            level: Int((clamped * 100).rounded()),
            isMuted: false,
            deviceName: name
        )
    }

    // MARK: - CoreAudio 读取（全失败容错，headless CI 也只是读数全 0 不崩）

    private static func snapshot() -> AudioInputStatus {
        guard let deviceID = defaultInputDeviceID() else {
            return status(averageVolume: nil, isMuted: false, deviceName: nil)
        }
        return status(
            averageVolume: averageInputVolume(deviceID: deviceID),
            isMuted: isInputMuted(deviceID: deviceID),
            deviceName: inputDeviceName(deviceID: deviceID)
        )
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func averageInputVolume(deviceID: AudioObjectID) -> Float32? {
        // 通道 1/2 均值，单声道退化为通道 1；纯数字输入设备可能整域不支持
        // VolumeScalar（无模拟增益级）→ nil，如实报 0 而非猜
        let left = channelVolume(deviceID: deviceID, channel: 1)
        let right = channelVolume(deviceID: deviceID, channel: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    private static func channelVolume(
        deviceID: AudioObjectID,
        channel: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func isInputMuted(deviceID: AudioObjectID) -> Bool {
        // 与 VolumeMonitor 同坑：部分设备只有通道级静音没有主静音，先主（element 0）后通道 1
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
            if status == noErr { return muted != 0 }
        }
        return false
    }

    private static func inputDeviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged 包装：直接 &cfString 会被编译器警告"对象引用装进原始指针"，
        // 属性尺寸 8 字节 = 一个 CFStringRef，按未持有引用取回即可
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedName)
        guard status == noErr else { return nil }
        return unmanagedName?.takeUnretainedValue() as String?
    }
}
