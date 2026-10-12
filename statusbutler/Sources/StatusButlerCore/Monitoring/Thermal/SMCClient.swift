import Foundation
import IOKit

// MARK: - SMC 参数结构（T-025）
// 以下结构必须与内核 AppleSMC user client 约定的 C 内存布局逐字节一致。
// 注意有两代布局：旧文档常见的"经典 64 字节"版会被新内核以 kIOReturnBadArgument
// 拒绝（macOS 26 arm64 真机实测）；当前有效的是下面这版 80 字节结构
// （与 stats 的 SMCKeyData_t 同源，真机探测通过）。测试用 MemoryLayout==80 钉死。

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0  // 值类型 fourcc（"fpe2"/"flt "/"sp78"…），按大端打包进 UInt32
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0  // 对齐占位：80 字节布局的组成部分，内核侧同名字段
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0  // 子命令：READ_KEYINFO=9 / READ_BYTES=5
    var data32: UInt32 = 0
    // 元组类型没有无参构造器（SMCBytes() 不合法），只能逐个写默认值
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - fourcc 工具

extension String {
    /// "TC0P" → 0x54433050。Swift 没有类 C 的多字符字面量 'TC0P'，自写大端打包。
    /// 仅接受 4 个 ASCII 字符，否则 nil（坏 key 宁可失败也不猜）。
    var fourCharCode: UInt32? {
        let chars = Array(utf8)
        guard chars.count == 4 else { return nil }
        let b0 = UInt32(chars[0])
        let b1 = UInt32(chars[1])
        let b2 = UInt32(chars[2])
        let b3 = UInt32(chars[3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

/// fourcc 数值还原成字符串。内核把类型常量（如 'fpe2'）按大端打包进 UInt32，
/// 与 String.fourCharCode 互为逆运算。
func fourCCString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

// MARK: - SMC 客户端

/// AppleSMC user client 的最小**只读**封装（经典 SMCParamStruct 调用，
/// IOServiceGetMatchingService + IOConnectCallStructMethod）。
/// 本类型不提供任何写路径：任务 T-025 只做温度/风扇读取；
/// 风扇域写入（FS!/F{n}Md）是红线二唯一豁免项，属后续控制任务，不在此处。
/// Sendable：IOConnectRef 非线程安全，包进 NSLock 保护的 Box；
/// Box 的 @unchecked 以前述锁纪律成立（所有访问先 lock）为前提。
public final class SMCClient: Sendable {
    private let box = SMCConnectionBox()

    public init() {}

    /// 连接 AppleSMC；虚拟机/无 SMC 服务/IOKit 异常返回 false，调用方据此整体降级（如 read()→nil）
    @discardableResult
    public func open() -> Bool { box.open() }

    /// 关闭并释放连接；幂等
    public func close() { box.close() }

    /// 读 key 的原始字节；不关心值类型时用（需要类型分发解码时用 readValue）
    public func readBytes(key: String) -> [UInt8]? {
        readValue(key: key)?.bytes
    }

    /// 读 key：返回 SMC 报告的值类型（fourcc 字符串）与原始字节；任一步失败返回 nil
    public func readValue(key: String) -> (type: String, bytes: [UInt8])? {
        box.readValue(key: key)
    }

    deinit { close() }
}

private final class SMCConnectionBox: @unchecked Sendable {
    // selector 固定为 KERNEL_INDEX_SMC(2)：AppleSMC user client 唯一的 struct method 入口，
    // 具体子命令走 data8 字段（社区标准，stats/smcFanControl 同款）
    private static let selector: UInt32 = 2
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let cmdReadBytes: UInt8 = 5

    private let lock = NSLock()
    // MACH_PORT_NULL 宏在本 SDK 导入为 Int32，与 io_connect_t(UInt32) 类型不合，直接用类型化 0
    private var connection: io_connect_t = 0

    func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connection == 0 else { return true }  // 重复 open 幂等（已连接直接成功）
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }  // matching dictionary 已被 consume，service 引用要还
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0
        else { return false }
        connection = conn
        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    func readValue(key: String) -> (type: String, bytes: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        guard connection != 0, let code = key.fourCharCode else { return nil }

        // 两段式（社区标准）：先 READ_KEYINFO 拿 dataSize/dataType，再 READ_BYTES 拿载荷
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = code
        input.data8 = Self.cmdReadKeyInfo
        guard call(input: &input, output: &output), output.result == 0 else { return nil }
        let dataSize = output.keyInfo.dataSize
        let type = fourCCString(output.keyInfo.dataType)

        input = SMCParamStruct()
        output = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = dataSize
        input.data8 = Self.cmdReadBytes
        guard call(input: &input, output: &output), output.result == 0 else { return nil }
        // 元组无法动态下标，整体取字节后按 dataSize 截取（prefix 自带钳制）
        let payload = withUnsafeBytes(of: output.bytes) { raw in
            Array(raw.prefix(Int(dataSize)))
        }
        return (type, payload)
    }

    private func call(input: inout SMCParamStruct, output: inout SMCParamStruct) -> Bool {
        var outputSize = MemoryLayout<SMCParamStruct>.size
        return IOConnectCallStructMethod(
            connection,
            Self.selector,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        ) == KERN_SUCCESS
    }
}
