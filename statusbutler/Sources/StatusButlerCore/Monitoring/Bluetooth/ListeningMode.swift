import CoreAudio
import Foundation

// A14-δ AirPods 聆听模式引擎（A2·S6 缺口）。
//
// 路线核查结论（对照 status-trio 参考实现 BluetoothListeningModeHAL.swift）：
// macOS 无公开 API 读写聆听模式——参考实现走 CoreAudio HAL 的私有属性选择子
// `lstm`（当前模式）/`lsms`（支持位掩码），它们不在公开 SDK 头文件里，属"私有 API
// 白名单外"（AGENTS 红线四：白名单只有 DDC/菜单栏整理/风扇域）。因此本文件把
// 私有 HAL 访问整体关进条件编译 STATUSBUTLER_ENABLE_LISTENING_MODE_PRIVATE_HAL
// （默认关闭，常规构建零私有 API 面），模型层（四态枚举/掩码解析/协议注入）保持
// 常开可测。扩白名单决策（A2 规格修订 + ForbiddenPatternGuardTests 同步）落地前，
// 组合根一律注入 UnavailableListeningModeController——fail-closed，不半可用。

// MARK: - 模型（常开，纯函数可测）

/// 聆听模式四态。raw 值与 HAL `lstm` 整数同源（参考实现真机口径）：
/// 0 = 未解析，1-4 之外属本构建不认识的模式，一律折叠 nil（不猜）。
public enum ListeningMode: UInt32, Equatable, Sendable, CaseIterable {
    case off = 1
    case noiseCancellation = 2
    case transparency = 3
    case adaptive = 4

    /// 面板可切换的目标态：off 只可观测、不可作为切换目的地
    /// （避免"关闭降噪"与"切通透"并列造成选择歧义，取消态由摘下耳机承担）。
    public static let selectableModes: [ListeningMode] = [
        .noiseCancellation, .transparency, .adaptive,
    ]

    /// 控件固定展示序（左→右），与 lsms 位序解耦——按钮不随支持掩码变化跳位
    public static let displayOrder: [ListeningMode] = [.noiseCancellation, .transparency, .adaptive]

    public var isUserSelectable: Bool { Self.selectableModes.contains(self) }

    /// 该模式在 lsms 支持掩码中占据的位；off 无位（掩码从不表示它）
    public var supportBit: UInt32? {
        switch self {
        case .noiseCancellation: return 0x1 << 0
        case .transparency: return 0x1 << 1
        case .adaptive: return 0x1 << 2
        case .off: return nil
        }
    }
}

public enum ListeningModeSupport {
    /// 本构建认识的 lsms 位全集（NC/通透/自适应）
    public static let recognizedMask: UInt32 = 0x1 << 0 | 0x1 << 1 | 0x1 << 2

    /// 掩码 → 可切换模式表（displayOrder 序）。未知位丢弃不猜——未来系统加位
    /// （如"对话增强"）不得凭空浮出半接线的按钮。
    public static func availableModes(fromSupportMask mask: UInt32) -> [ListeningMode] {
        ListeningMode.displayOrder.filter { mode in
            guard let bit = mode.supportBit else { return false }
            return mask & bit != 0
        }
    }

    /// 掩码是否携带本构建未命名的位（调试日志可见，UI 不消费）
    public static func hasUnknownBits(_ mask: UInt32) -> Bool {
        mask & ~recognizedMask != 0
    }
}

/// `lstm` 原始整数 → 模式。0/越界值 fail-closed 为 nil，控制层据此不点亮任何选中态。
public enum ListeningModeRawValue {
    public static func mode(fromRawValue raw: UInt32) -> ListeningMode? {
        ListeningMode(rawValue: raw)
    }
}

// MARK: - 控制协议（注入面）

/// 聆听模式读写面（`-ing` 后缀惯例；read 支持查询可同步，set 含读回确认走 async）
public protocol ListeningModeControlling: Sendable {
    func read(deviceID: AudioDeviceID) -> ListeningMode?
    func isSupported(_ mode: ListeningMode, deviceID: AudioDeviceID) -> Bool
    func set(_ mode: ListeningMode, deviceID: AudioDeviceID) async -> Bool
}

/// 默认注入实现：白名单未扩前一律 fail-closed——read 恒 nil、set 恒 false。
/// 组合根现在就能接线（面板据此隐藏聆听模式分区），扩白名单后只换这一个注入。
public struct UnavailableListeningModeController: ListeningModeControlling {
    public init() {}

    public func read(deviceID: AudioDeviceID) -> ListeningMode? { nil }
    public func isSupported(_ mode: ListeningMode, deviceID: AudioDeviceID) -> Bool { false }
    public func set(_ mode: ListeningMode, deviceID: AudioDeviceID) async -> Bool { false }
}

// MARK: - 私有 HAL 路线（默认关闭：红线四白名单外，扩白名单决策见文件头）

#if STATUSBUTLER_ENABLE_LISTENING_MODE_PRIVATE_HAL

/// 私有选择子以四字符码原值解析，不依赖任何 SDK 头声明。
/// 每次访问先 AudioObjectHasProperty 运行时探测——系统更新移除属性时整域
/// fail-closed（属性消失 = 面板隐藏该设备控制），绝不假设它还在。
enum ListeningModeHALProperty {
    /// `lstm`：当前聆听模式（UInt32），也是模式切换的写入目标
    static let listeningMode: AudioObjectPropertySelector = 0x6C73_746D
    /// `lsms`：支持的聆听模式位掩码（UInt32）
    static let listeningModeSupport: AudioObjectPropertySelector = 0x6C73_6D73

    static let scope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
    static let element = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    static let expectedSize = UInt32(MemoryLayout<UInt32>.size)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// HAL 四字节属性读写缝（测试注入假后端，CoreAudio 调用不进测试）
protocol ListeningModePropertyReading: Sendable {
    func hasProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool
    func dataSize(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32?
    func readUInt32(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32?
    func isSettable(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool
    func writeUInt32(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> OSStatus
}

/// 生产后端：直连 AudioObject API。nonisolated（CoreAudio 属性访问线程安全，
/// 全局 scope 主 element 的四字节读写无共享状态）
struct CoreAudioListeningModePropertyReader: ListeningModePropertyReading {
    func hasProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = ListeningModeHALProperty.address(selector)
        return AudioObjectHasProperty(deviceID, &address)
    }

    func dataSize(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = ListeningModeHALProperty.address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return nil
        }
        return size
    }

    func readUInt32(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = ListeningModeHALProperty.address(selector)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = UInt32(0)
        var size = ListeningModeHALProperty.expectedSize
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    func isSettable(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = ListeningModeHALProperty.address(selector)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    func writeUInt32(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        _ value: UInt32
    ) -> OSStatus {
        var address = ListeningModeHALProperty.address(selector)
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &mutableValue
        )
    }
}

/// 读回等待缝（测试注入零等待实现，16 次预算在测试里不真花 800ms）
protocol ListeningModeSleeping: Sendable {
    func sleep(for duration: Duration) async
}

struct ClockListeningModeSleeper: ListeningModeSleeping {
    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// 私有 HAL 控制器：read = 原始值解析；set = 先复检支持位与可写，写后有限次
/// 延时读回确认——setter 返回 noErr 只代表控制面收下了请求，不代表耳机认了，
/// 只有 `lstm` 读回落在目标态才算成功（参考实现同口径）。
struct CoreAudioListeningModeController: ListeningModeControlling {
    let reader: any ListeningModePropertyReading
    let sleeper: any ListeningModeSleeping
    let retryAttempts: Int
    let retryDelay: Duration

    init(
        reader: any ListeningModePropertyReading = CoreAudioListeningModePropertyReader(),
        sleeper: any ListeningModeSleeping = ClockListeningModeSleeper(),
        retryAttempts: Int = 16,
        retryDelay: Duration = .milliseconds(50)
    ) {
        self.reader = reader
        self.sleeper = sleeper
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
    }

    func read(deviceID: AudioDeviceID) -> ListeningMode? {
        guard let raw = reader.readUInt32(deviceID, ListeningModeHALProperty.listeningMode) else {
            return nil
        }
        return ListeningModeRawValue.mode(fromRawValue: raw)
    }

    func isSupported(_ mode: ListeningMode, deviceID: AudioDeviceID) -> Bool {
        guard mode.isUserSelectable,
              let bit = mode.supportBit,
              let mask = reader.readUInt32(deviceID, ListeningModeHALProperty.listeningModeSupport)
        else { return false }
        return mask & bit != 0
    }

    func set(_ mode: ListeningMode, deviceID: AudioDeviceID) async -> Bool {
        guard mode.isUserSelectable else { return false }
        guard reader.hasProperty(deviceID, ListeningModeHALProperty.listeningMode),
              let currentRaw = reader.readUInt32(deviceID, ListeningModeHALProperty.listeningMode)
        else { return false }
        guard isSupported(mode, deviceID: deviceID) else { return false }
        guard reader.isSettable(deviceID, ListeningModeHALProperty.listeningMode) else { return false }
        // 已在目标态：不写也不读回（重复点击不产生冗余请求）
        if ListeningModeRawValue.mode(fromRawValue: currentRaw) == mode { return true }

        guard reader.writeUInt32(deviceID, ListeningModeHALProperty.listeningMode, mode.rawValue) == noErr
        else { return false }

        // 先等后读：HAL 缓存异步收敛，立刻读回大概率仍是旧值
        for _ in 0..<max(1, retryAttempts) {
            await sleeper.sleep(for: retryDelay)
            guard let raw = reader.readUInt32(deviceID, ListeningModeHALProperty.listeningMode) else {
                return false  // 属性中途消失：无从确认，按失败收敛
            }
            if ListeningModeRawValue.mode(fromRawValue: raw) == mode { return true }
        }
        return false
    }
}

#endif
