import CoreAudio
import Foundation

// A14-δ DDC 音量（A2·S6 缺口：外接显示器此前只有亮度/对比度）。
// VCP 寄存器码经 status-trio 参考实现确认：speaker volume = 0x62
// （DDCDisplayTransport.volumeVCP 同码钉死）。帧格式沿用本仓库 DDCFrame
// 的 ddcctl/MonitorControl 社区口径（源 0x51/类型 0x82/校验和基址 0x50），
// 与亮度 0x10、对比度 0x12 同一条 I2C 管道——不引入参考实现另一条
// chip 0x37 AppleSiliconDDC 帧路线，避免同一显示器两套帧口径并存。

// MARK: - 寄存器与客户端扩展

extension DDCFrame {
    /// MCCS speaker volume 寄存器（0-100 值域与亮度一致）
    static let volumeRegister: UInt8 = 0x62
}

extension DDCClient {
    /// 读扬声器音量（寄存器 0x62，0-100 相对值）；任一步失败 nil 静默降级（DDC-04 同源）
    public func readVolume(of display: DDCDisplay) -> Int? {
        readValue(register: DDCFrame.volumeRegister, of: display)
    }

    /// 写扬声器音量（寄存器 0x62，值经 clampDDCValue 钳制）；失败 false 静默降级
    @discardableResult
    public func writeVolume(_ value: Int, to display: DDCDisplay) -> Bool {
        writeDDC(register: DDCFrame.volumeRegister, value: clampDDCValue(value), to: display)
    }
}

// MARK: - 音量路由（纯函数 + 注入判定）

/// 音量操作去向：外接显示器扬声器走 DDC（系统不知道显示器的硬件音量，
/// macOS 音量对 HDMI/DP 音频输出恒满格），其余一切走系统音量。
public enum DDCVolumeRoute: Equatable, Sendable {
    case system
    case ddc
}

public enum DDCRouting {
    /// 默认外接屏判定：默认输出设备的 ModelUID 含 "Display"（大小写不敏感）。
    /// 这是经验启发式——Apple 把外接屏音频端点命名为 "DisplayPort"/厂商+Display
    /// 形态，而内建扬声器是 "MacBook Pro Speakers" 一类；误判代价不对称
    /// （把系统音量误路由到 DDC = 面板滑杆失灵），所以不确定时永远回系统音量。
    public static let defaultExternalDisplayMatcher: @Sendable (String) -> Bool = { modelUID in
        modelUID.lowercased().contains("display")
    }

    /// 路由决策（纯函数）：
    /// - ModelUID 判定外接屏 + DDC 通道可用 → .ddc
    /// - 内建扬声器 / nil（无默认设备或读不到 ModelUID）/ 空白串 → .system
    /// - 判定外接屏但 DDC 不可用（dlsym 失败/沙盒）→ .system（降级不硬路由）
    public static func volumeRoute(
        defaultOutputModelUID: String?,
        ddcAvailable: Bool,
        isExternalDisplay: @Sendable (String) -> Bool = DDCRouting.defaultExternalDisplayMatcher
    ) -> DDCVolumeRoute {
        guard ddcAvailable,
              let uid = defaultOutputModelUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty,
              isExternalDisplay(uid)
        else { return .system }
        return .ddc
    }

    // MARK: live 取数（组合根用；读不到 nil，路由决策随之 fail-safe 到 .system）

    /// 当前默认输出设备的 ModelUID；无输出硬件/CoreAudio 查询失败 → nil
    public static func defaultOutputModelUID() -> String? {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress, 0, nil, &deviceSize, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyModelUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged 包装：避免把 CFString 对象引用直接装进原始指针（编译器警告路径）
        var unmanagedUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &unmanagedUID) == noErr
        else { return nil }
        return unmanagedUID?.takeUnretainedValue() as String?
    }
}
