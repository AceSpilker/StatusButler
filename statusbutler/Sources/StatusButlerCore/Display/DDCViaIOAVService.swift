import Foundation
import IOKit

// MARK: - DDC/CI over IOAVService（T-050a · A11 E14 DDC-01~04）
//
// 红线四白名单路线：IOAVServiceReadI2C/WriteI2C 是外接屏 DDC/CI 的唯一可行通道，
// 符号在 IOKit 二进制中导出但头文件不公开（SDK 无 IOAVServiceLib.h）。不加 C target、
// 不显式 link 私有框架：dlopen(nil) 在已加载映像（本 target 已 import IOKit）里按名解析。
// 任一符号缺失（系统改名/裁剪）→ 整域静默降级（DDC-04）：isAvailable=false、读写返回
// nil/false，UI 据此隐藏亮度功能，绝不弹窗、绝不崩溃。

/// IOAVServiceRef（C: struct IOAVService *）：不透明 CF 对象，仅以裸指针形态流转。
typealias IOAVServiceRef = OpaquePointer?

/// dlsym 解析出的调用面。CFRelease 在 Swift 侧被显式标记 unavailable（引导走 ARC），
/// 只能一并 dlsym；release 独立成成员同时让测试能注入假 AVService 指针而不触发真实释放。
struct IOAVServiceSymbols: Sendable {
    typealias CreateFn = @convention(c) (io_service_t) -> IOAVServiceRef
    typealias ReadI2CFn = @convention(c) (
        IOAVServiceRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>?, UInt32
    ) -> kern_return_t
    typealias WriteI2CFn = @convention(c) (
        IOAVServiceRef, UInt32, UInt32, UnsafePointer<UInt8>?, UInt32
    ) -> kern_return_t
    typealias ReleaseFn = @convention(c) (OpaquePointer) -> Void

    let create: CreateFn
    let readI2C: ReadI2CFn
    let writeI2C: WriteI2CFn
    let release: ReleaseFn

    /// 四个符号齐备才成表；否则 nil（调用方整体降级，不让"半个通道"半途崩）
    static func resolve() -> IOAVServiceSymbols? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symCreate = dlsym(handle, "IOAVServiceCreateWithService"),
              let symRead = dlsym(handle, "IOAVServiceReadI2C"),
              let symWrite = dlsym(handle, "IOAVServiceWriteI2C"),
              let symRelease = dlsym(handle, "CFRelease")
        else { return nil }
        return IOAVServiceSymbols(
            create: unsafeBitCast(symCreate, to: CreateFn.self),
            readI2C: unsafeBitCast(symRead, to: ReadI2CFn.self),
            writeI2C: unsafeBitCast(symWrite, to: WriteI2CFn.self),
            release: unsafeBitCast(symRelease, to: ReleaseFn.self)
        )
    }
}

// MARK: - DDC/CI 帧构造（MCCS over I2C 从地址 0x51，纯函数）

/// 帧口径与 ddcctl/MonitorControl 同源（真机全系实证）：源 0x51、类型 0x82、
/// 长度 = 载荷字节数，校验和基址取 0x50（社区口径，非 0x51）。
enum DDCFrame {
    /// MCCS 亮度寄存器（DDC-01）
    static let brightnessRegister: UInt8 = 0x10
    /// MCCS 对比度寄存器（DDC-01）
    static let contrastRegister: UInt8 = 0x12
    /// DDC/CI 芯片 I2C 从地址
    static let i2cAddress: UInt32 = 0x51

    private static let sourceAddress: UInt8 = 0x51
    private static let commandType: UInt8 = 0x82

    private static func checksum(payload: [UInt8]) -> UInt8 {
        let sum = UInt16(0x50 + Int(commandType) + payload.count)
            + payload.reduce(UInt16(0)) { $0 + UInt16($1) }
        return UInt8(truncatingIfNeeded: sum)
    }

    /// 设值帧：[0x51, 0x82, 0x03, 寄存器, 值高 8 位, 值低 8 位, 校验和]
    static func setValueCommand(register: UInt8, value: UInt8) -> [UInt8] {
        let payload = [register, 0, value]  // 16 位值，0-100 域内高字节恒 0
        var frame = [sourceAddress, commandType, UInt8(payload.count)] + payload
        frame.append(checksum(payload: payload))
        return frame
    }

    /// 读当前值请求帧：[0x51, 0x82, 0x01, 寄存器, 校验和]
    static func getValueCommand(register: UInt8) -> [UInt8] {
        let payload = [register]
        var frame = [sourceAddress, commandType, UInt8(payload.count)] + payload
        frame.append(checksum(payload: payload))
        return frame
    }
}

/// DDC 值域纯钳制：0...100 是一切 DDC 亮度/对比度写入的唯一出口形态（DDC-01 值域约定）。
/// 各显示器 MCCS 上限不一（0-100/0-255），产品域统一收 0-100，换算只发生在帧构造处。
public func clampDDCValue(_ value: Int) -> Int {
    Swift.min(Swift.max(value, 0), 100)
}

/// 显示器标识：IORegistry Entry ID（一次开机周期内稳定；跨调用重解析服务用，
/// 比 mach 端口名适合做持久标识，服务端口可能因热插拔失效）。
public struct DDCDisplay: Equatable, Hashable, Sendable {
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

// MARK: - DDC 客户端

/// 外接屏 DDC 读写客户端（结构体 + 无状态：每次调用按 Entry ID 重解析服务，
/// 不缓存 AVService——服务端口会随热插拔失效，重解析换取免失效处理）。
public struct DDCClient: Sendable {
    private let symbols: IOAVServiceSymbols?

    /// DDC 通道可用性：dlsym 解析失败即 false（整域静默降级的唯一开关）
    public var isAvailable: Bool { symbols != nil }

    public init() {
        self.symbols = IOAVServiceSymbols.resolve()
    }

    /// 测试注入假函数指针：live 环境无法复现"符号缺失/创建失败"，降级路径由此验证
    init(symbols: IOAVServiceSymbols?) {
        self.symbols = symbols
    }

    /// 枚举显示器（IOServiceMatching("IODisplayConnect") 遍历）。
    /// 仅纳入 AVService 可创建的条目（探测性 create 后立即释放）；
    /// 无显示器/受限环境（CI 沙盒）返回空数组——属合法降级而非错误。
    public func discoverDisplays() -> [DDCDisplay] {
        guard let symbols else { return [] }
        var displays: [DDCDisplay] = []
        forEachDisplayService { service, entryID in
            if let probe = symbols.create(service) {
                symbols.release(probe)
                displays.append(DDCDisplay(id: entryID))
            }
        }
        return displays
    }

    /// 读亮度（寄存器 0x10，返回 0-100 相对值）；任一步失败返回 nil 静默降级（DDC-04）
    public func readBrightness(of display: DDCDisplay) -> Int? {
        readValue(register: DDCFrame.brightnessRegister, of: display)
    }

    /// 写亮度（寄存器 0x10，值经 clampDDCValue 钳制）；失败返回 false 静默降级
    @discardableResult
    public func writeBrightness(_ value: Int, to display: DDCDisplay) -> Bool {
        writeDDC(register: DDCFrame.brightnessRegister, value: value, to: display)
    }

    /// 写对比度（寄存器 0x12，值经 clampDDCValue 钳制）；失败返回 false 静默降级
    @discardableResult
    public func writeContrast(_ value: Int, to display: DDCDisplay) -> Bool {
        writeDDC(register: DDCFrame.contrastRegister, value: value, to: display)
    }

    // MARK: 内部

    /// 读当前值：两段式（社区标准）——先写"读当前值"请求，再读 8 字节应答，
    /// 应答布局 [源, 0x82, 长度, 操作码, maxHi, maxLo, curHi, curLo]，
    /// 按 cur/max 比例换算 0-100（不同显示器 MCCS 满量程不一）。
    private func readValue(register: UInt8, of display: DDCDisplay) -> Int? {
        guard let symbols else { return nil }
        return withAVService(for: display, symbols: symbols) { av in
            let request = DDCFrame.getValueCommand(register: register)
            guard symbols.writeI2C(
                av, DDCFrame.i2cAddress, 0, request, UInt32(request.count)
            ) == KERN_SUCCESS else { return nil }
            var reply = [UInt8](repeating: 0, count: 8)
            guard symbols.readI2C(
                av, DDCFrame.i2cAddress, 0, &reply, UInt32(reply.count)
            ) == KERN_SUCCESS else { return nil }
            let max = (UInt16(reply[4]) << 8) | UInt16(reply[5])
            let current = (UInt16(reply[6]) << 8) | UInt16(reply[7])
            guard max > 0 else { return nil }  // 满量程 0 = 应答格式坏，宁可不猜
            return clampDDCValue(Int((Double(current) / Double(max) * 100).rounded()))
        }
    }

    private func writeDDC(register: UInt8, value: Int, to display: DDCDisplay) -> Bool {
        // 双重出口钳制：public 入口已 clamp，这里再钉一次 0-100（防未来调用方绕过）
        guard let symbols, (0...100).contains(value), let byte = UInt8(exactly: value) else {
            return false
        }
        return withAVService(for: display, symbols: symbols) { av in
            let command = DDCFrame.setValueCommand(register: register, value: byte)
            // TODO(DDC-04): 写后回读校验 + 指数退避随面板接线（T-050b）落地，
            // 本轮保持单次写以免冒烟节奏被慢显示器拖垮
            return symbols.writeI2C(
                av, DDCFrame.i2cAddress, 0, command, UInt32(command.count)
            ) == KERN_SUCCESS
        } ?? false
    }

    /// 遍历 IODisplayConnect 服务，回调 (service, entryID)；service 生命周期由本函数管理，
    /// 回调内不得释放。matching 失败（无 IOKit 环境）静默返回。
    private func forEachDisplayService(_ body: (io_service_t, UInt64) -> Void) {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator
        ) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }  // matching dictionary 已被 consume，迭代器引用要还
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var entryID = UInt64(0)
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == kIOReturnSuccess else {
                continue
            }
            body(service, entryID)
        }
    }

    /// 按 Entry ID 重解析服务并创建 AVService；create 失败（内建屏/服务已消失）→ nil。
    /// AVService 用毕即释（body 返回后 defer release），不跨调用缓存。
    private func withAVService<T>(
        for display: DDCDisplay,
        symbols: IOAVServiceSymbols,
        _ body: (OpaquePointer) -> T?
    ) -> T? {
        var found: T?
        forEachDisplayService { service, entryID in
            guard entryID == display.id, found == nil else { return }
            guard let av = symbols.create(service) else { return }
            defer { symbols.release(av) }
            found = body(av)
        }
        return found
    }
}
