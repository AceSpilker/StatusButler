import Foundation
import IOBluetooth
import IOKit

// A14-δ 蓝牙设备操作引擎（A2·S7：连接/断开从"无操作"到可执行）。
// IOBluetooth 的 openConnection/closeConnection 是同步阻塞 API（设备不在范围时
// 可等到页超时，秒级）——实现把阻塞调用整体折进 detached 后台任务，调用方
// （通常是主 actor 的面板）只拿回 Bool，IOBluetoothDevice 引用绝不跨并发边界外泄。

// MARK: - 操作协议

/// 蓝牙设备操作面（`-ing` 后缀惯例，面板/测试注入假实现）
public protocol BluetoothOperating: Sendable {
    func connect(address: String) async -> Bool
    func disconnect(address: String) async -> Bool
}

extension BluetoothOperating {
    /// 面板单入口便捷形态（默认实现走双方法）
    @discardableResult
    public func setConnected(_ connected: Bool, address: String) async -> Bool {
        connected ? await connect(address: address) : await disconnect(address: address)
    }
}

// MARK: - 设备句柄收窄

/// IOBluetoothDevice 的最小收窄：真机由 IOBluetoothDevice 满足；测试注入假句柄
/// 验证 IOReturn → Bool 的状态映射。只暴露连接两向，其余能力（配对/服务浏览）不进面。
public protocol BluetoothDeviceHandle: AnyObject {
    @discardableResult func performConnect() -> IOReturn
    @discardableResult func performDisconnect() -> IOReturn
}

extension IOBluetoothDevice: BluetoothDeviceHandle {
    public func performConnect() -> IOReturn { openConnection() }
    public func performDisconnect() -> IOReturn { closeConnection() }
}

// MARK: - 地址归一（纯函数）

/// 蓝牙地址归一：蓝牙面板的地址串来自 addressString（"xx-xx-…"小写短横线），
/// 但 UI/剪贴板流转中冒号大写形态同样合法——归一到统一形态后才可做键匹配与
/// 预筛。非 17 字符标准形态（含空串/垃圾）归 ""，调用方据此直接短路。
public enum BluetoothDeviceAddress {
    public static func normalized(_ address: String) -> String {
        let lowered = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ":", with: "-")
        // "xx-xx-xx-xx-xx-xx" = 12 位十六进制 + 5 个分隔符
        guard lowered.count == 17 else { return "" }
        let wellFormed = lowered.allSatisfy { character in
            character == "-" || (character.isASCII && character.isHexDigit)
        }
        return wellFormed ? lowered : ""
    }
}

// MARK: - HID 确认模型（纯函数）

/// 误触代价模型：连接 HID 设备（键盘/鼠标/触控板/手柄）会立刻接管输入面，
/// 在"最近断开"或批量重连场景下需要二次确认；音频/穿戴件连错只是没声音，
/// 不弹确认。纯函数——UI 弹不弹、怎么弹归展示层，这里只回答"要不要"。
public enum BluetoothHIDConfirmationModel {
    public static func needsConfirmation(_ kind: BluetoothDeviceKind) -> Bool {
        switch kind {
        case .keyboard, .mouse, .trackpad, .gamepad:
            return true
        case .headphone, .speaker, .wearable, .other:
            return false
        }
    }
}

// MARK: - IOBluetooth 实现

/// 地址 → 已配对设备句柄的解析器。默认实现走 IOBluetoothDevice(addressString:)；
/// 坏地址在上层已被归一预筛挡下，不会到这。
public typealias BluetoothDeviceResolver = @Sendable (String) -> (any BluetoothDeviceHandle)?

public struct IOBluetoothOperations: Sendable, BluetoothOperating {
    private let resolve: BluetoothDeviceResolver

    public init(resolve: BluetoothDeviceResolver? = nil) {
        // 默认解析器在体内选取而非默认参数——public init 的默认参数会被写进模块
        // 接口，私有 static 闭包在那里不可见（编译期即拒）
        self.resolve = resolve ?? IOBluetoothOperations.resolveViaAddressString
    }

    public func connect(address: String) async -> Bool {
        await request(address: address, connect: true)
    }

    public func disconnect(address: String) async -> Bool {
        await request(address: address, connect: false)
    }

    // MARK: 内部

    /// 坏地址在进 resolver 前短路：默认 resolver 是同步往返 bluetoothd 的贵调用，
    /// 空/畸形地址（空串、复制残缺）不值得一次系统查询。
    private func request(address: String, connect: Bool) async -> Bool {
        guard !BluetoothDeviceAddress.normalized(address).isEmpty else { return false }
        let resolve = self.resolve
        return await Task.detached(priority: .userInitiated) {
            Self.outcome(resolved: resolve(address), connect: connect)
        }.value
    }

    /// 状态映射纯函数：句柄缺失（已解除配对）→ false；IOReturn 只有
    /// kIOReturnSuccess 算成功——kIOReturnBusy 等中间态不当成功，连接是否
    /// 真的建立以设备连接态快照为准，这里不猜。
    public static func outcome(resolved: (any BluetoothDeviceHandle)?, connect: Bool) -> Bool {
        guard let device = resolved else { return false }
        let status = connect ? device.performConnect() : device.performDisconnect()
        return status == kIOReturnSuccess
    }

    /// 默认解析器：现代 SDK 里 deviceWithAddressString: 已被 init(addressString:) 取代
    private static let resolveViaAddressString: BluetoothDeviceResolver = { address in
        IOBluetoothDevice(addressString: address)
    }
}
