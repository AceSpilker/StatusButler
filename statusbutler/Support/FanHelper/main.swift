// StatusButler 风扇特权 Helper（T-222 代码半场 · A5 TF-20 / 红线二唯一白名单例外）
//
// ── 形态与协议 ────────────────────────────────────────────────────────────────
// 独立 Swift 可执行（本文件不进 SwiftPM 构建图，Support/ 不在 target 路径里；
// 由同目录 build-fanhelper.sh 用 swiftc 单独编出 .build/fanhelper/statusbutler-fanhelper，
// 与 MobileBatteryHelper 同纪律——特权件与主程序物理隔离，审计面集中一个文件）。
//
// stdin/stdout JSON 行协议（每行一请求一应答，循环直到 EOF）：
//   请求 {"action":"set","key":"FS!" ,"value":2}        → 强制手动模式（01=系统自动，02=强制）
//   请求 {"action":"set","key":"F0Md","value":4000}     → 0 号风扇目标转速（RPM）
//   请求 {"action":"ping"}                              → 存活/协议握手（零副作用）
//   应答 {"ok":true} 或 {"ok":false,"error":"人类可读原因"}（应答只写 stdout，
//   诊断只写 stderr——契约只属于 stdout）。
//   白名单外的任何 key：stdout 补一条 {"ok":false,...} 后立即 exit 1，
//   错误明细写 stderr——调用方（FanHelperClient）把它当"helper 拒绝"处理。
//
// ── 红线二白名单依据（A2·S12 修订版 / A5 第 7 节）────────────────────────────
// 原红线二禁止任何 SMC 写入与特权进程；E11（A4·R-1）修订后**风扇域是唯一例外**：
// 仅放行 FS!（强制模式）与 F{n}Md（目标转速）。本文件是全仓库唯一实现风扇域
// SMC 写路径的地方：Core 的 SMCClient 刻意只读（T-025 注释钉死"写路径属后续
// 控制任务"），写调用在本文件内独立实现——特权件里白名单与写入物理同处，
// 不存在"绕过白名单直接碰写入"的拼装面。充电/电源域键（BC*、CH*、AC*、…）
// 一概没有代码路径可达：validate 白名单之外先拒绝，写入函数只接受白名单键
// 已编码后的字节。ForbiddenPatternGuardTests 钉死 Sources/ 里风扇键只允许
// 出现在 Thermal/ 模块；本文件在 Support/，由本套件自己的键断言测试钉死。
//
// ── 安装协议（SMAppService LaunchDaemon，本任务不触发安装动作）──────────────
// 1. 组包时 helper 与模板 com.statusbutler.fanhelper.plist 一起进 .app 的
//    Contents/Resources/FanHelper/；
// 2. 首次启用风扇控制（设置页/弹层）→ 面板解释并请求：把 plist 拷进
//    /Library/LaunchDaemons/（Label = com.statusbutler.fanhelper，
//    Program 指向 helper 绝对路径）→ SMAppService.daemon(plistName).register()
//    → macOS 弹系统管理员授权（用户输密码）——安装是用户的显式动作；
// 3. register 成功后 LaunchDaemon 以 root 常驻，本协议 stdin/stdout 改经
//    XPC/Unix 域套接字桥接（传输层升级不动白名单语义）；
// 4. 卸载：SMAppService unregister + 删 plist，随 App 设置页"恢复系统控制并
//    卸载 Helper"一键出口（A5 安全护栏"透明可卸"）。
// 未安装时 App 以当前用户直接拉起本 helper：Apple Silicon 上写调用会被内核
// 拒绝（这正是需要 root helper 的原因），App 侧据此诚实降级"需安装 Helper"。

import Foundation
import IOKit

// MARK: - SMC 结构（与 Core 的 SMCClient 同源的 80 字节布局）
// 逐字节一致是内核 AppleSMC user client 的硬约定（旧 64 字节版会被
// kIOReturnBadArgument 拒绝）；特权件不链接 Core，布局在此独立钉死，
// MemoryLayout 由构建脚本冒烟断言兜底。

struct HelperSMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct HelperSMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct HelperSMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias HelperSMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct HelperSMCParamStruct {
    var key: UInt32 = 0
    var vers = HelperSMCVersion()
    var pLimitData = HelperSMCLimitData()
    var keyInfo = HelperSMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: HelperSMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - 白名单（红线二唯一例外，本文件的安全边界就是这一个函数）

enum FanHelperWhitelist {
    /// 仅放行 FS!（强制模式开关）与 F{n}Md（风扇 n 目标转速）。
    /// 风扇序号上限 8 对齐 ThermalMonitor.maxFanCount 的防呆口径；
    /// 其余一切键（温度读键、充电/电源域键、未来未知键）一律拒绝。
    static func isAllowed(key: String) -> Bool {
        if key == "FS!" { return true }
        guard key.count == 4, key.hasPrefix("F"), key.hasSuffix("Md") else { return false }
        let digits = key.dropFirst().dropLast(2)  // 后缀 "Md" 占 2 字符，只留风扇序号位
        guard digits.count == 1, let fan = digits.first, fan.isNumber else { return false }
        return (0...7).contains(Int(String(fan)) ?? -1)
    }
}

// MARK: - SMC 写入（白名单键专用编码）

enum FanHelperSMC {
    private static let selector: UInt32 = 2  // KERNEL_INDEX_SMC，唯一 struct method 入口
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let cmdWriteBytes: UInt8 = 6  // SMC_WRITE_BYTES（读路径是 5，写是 6——社区标准）

    /// 协议键名 → SMC fourCC。"FS!" 是 3 字符习惯写法，SMC 键位实为 4 字节
    /// "FS! "（尾随空格补齐，0x46532120——smcFanControl 同款）；真机探测证明
    /// 不补空格的 3 字节编码查键即 not found。
    static func keyCode(forProtocolKey key: String) -> UInt32? {
        if key == "FS!" {
            return 0x46532120
        }
        guard FanHelperWhitelist.isAllowed(key: key) else { return nil }
        let chars = Array(key.utf8)
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }

    /// 按 SMC 自己报告的载荷类型编码写入值（读侧 ThermalMonitor.fanRPM 同哲学：
    /// 类型随机型浮动，只信 SMC 报告的，不赌固定布局）。
    /// - FS!：期望 1 字节（01 自动/02 强制）；值域外拒绝。
    /// - F{n}Md：fpe2(2B，值×4 大端，Intel 经典) / flt(4B 本机序 Float32) /
    ///   ui8(1B 直通，值 0–255)——真机实测 Apple Silicon 的 F0Md 即 ui8。
    /// 返回 nil = 该机型载荷类型与 RPM 语义无法对上：宁可诚实拒绝也不写
    /// 语义不明的字节（比如把 4000 RPM 塞进 1 字节截成 160）。
    static func encodedBytes(key: String, value: Int, dataSize: UInt32, dataType: String) -> [UInt8]? {
        if key == "FS!" {
            guard value == 1 || value == 2, dataSize == 1 else { return nil }
            return [UInt8(value)]
        }
        switch (dataSize, dataType.trimmingCharacters(in: .whitespaces)) {
        case (2, "fpe2"):
            guard value >= 0, value <= 16383 else { return nil }  // ×4 后须在 UInt16 内
            let encoded = UInt16(value * 4)
            return [UInt8(encoded >> 8), UInt8(encoded & 0xFF)]
        case (4, "flt"):
            guard value >= 0 else { return nil }
            return withUnsafeBytes(of: Float32(value)) { Array($0) }
        case (1, "ui8"):
            // ui8 载荷装不下任何真实 RPM（物理风扇下限 >255）：接受 0–255 直通
            // 仅服务于"未知语义的 1 字节命令"探测；正常转速路径会被下限钳制拒绝
            guard (0...255).contains(value) else { return nil }
            return [UInt8(value)]
        default:
            return nil
        }
    }

    /// 打开 AppleSMC 连接。返回 (连接, 失败原因)：conn == 0 表示失败
    /// （虚拟机/无 SMC 服务/IOKit 异常），原因给调用方上浮成 ok:false。
    static func openConnection() -> (conn: io_connect_t, failure: String) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return (0, "AppleSMC 服务不存在（虚拟机/驱动未载）") }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else {
            return (0, "IOServiceOpen AppleSMC 失败")
        }
        return (conn, "")
    }

    /// 写一个白名单键。返回 nil = 成功；非 nil = 人类可读错误。
    static func write(conn: io_connect_t, key: String, value: Int) -> String? {
        guard let code = keyCode(forProtocolKey: key) else { return "键 \(key) 不在白名单或非法" }
        // 先 READ_KEYINFO 拿 dataSize/dataType：载荷按机器报告的类型编码
        var input = HelperSMCParamStruct()
        var output = HelperSMCParamStruct()
        input.key = code
        input.data8 = cmdReadKeyInfo
        guard call(conn: conn, input: &input, output: &output), output.result == 0 else {
            return "读 \(key) 键信息失败（该机型无此键或权限不足；Apple Silicon 需 root helper）"
        }
        let dataSize = output.keyInfo.dataSize
        let dataType = fourCCString(output.keyInfo.dataType)
        guard let payload = encodedBytes(key: key, value: value, dataSize: dataSize, dataType: dataType) else {
            return "键 \(key) 的值 \(value) 无法按本机载荷类型（\(dataType)/\(dataSize)B）安全编码"
        }
        input = HelperSMCParamStruct()
        output = HelperSMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = dataSize
        input.data8 = cmdWriteBytes
        for (index, byte) in payload.enumerated() where index < 32 {
            withUnsafeMutableBytes(of: &input.bytes) { raw in
                raw[index] = byte
            }
        }
        guard call(conn: conn, input: &input, output: &output) else {
            return "SMC 写调用失败（Apple Silicon 需 root helper：请经设置页安装）"
        }
        if output.result != 0 {
            return "SMC 拒绝写入 \(key)（result=\(output.result)，权限或模式不符）"
        }
        return nil
    }

    private static func fourCCString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func call(conn: io_connect_t, input: inout HelperSMCParamStruct, output: inout HelperSMCParamStruct) -> Bool {
        var outputSize = MemoryLayout<HelperSMCParamStruct>.size
        return IOConnectCallStructMethod(
            conn,
            selector,
            &input,
            MemoryLayout<HelperSMCParamStruct>.size,
            &output,
            &outputSize
        ) == KERN_SUCCESS
    }
}

// MARK: - JSON 行协议

enum FanHelperProtocol {
    struct Request {
        var action: String
        var key: String?
        var value: Int?
    }

    /// 解析一行请求。坏 JSON/缺 action 返回 nil（按协议级错误回 ok:false，进程续命）。
    static func parseRequest(line: String) -> Request? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String
        else { return nil }
        let key = object["key"] as? String
        // 数字/字符串双形态防御：客户端侧一律发数字，手调协议时字符串也别炸
        let rawValue = object["value"]
        let value: Int?
        if let n = rawValue as? NSNumber { value = n.intValue }
        else if let s = rawValue as? String { value = Int(s) }
        else { value = nil }
        return Request(action: action, key: key, value: value)
    }

    static func okJSON() -> String { "{\"ok\":true}" }

    static func errorJSON(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"ok\":false,\"error\":\"\(escaped)\"}"
    }
}

// MARK: - 主循环

// 单连接贯穿整个进程：AppleSMC 连接的建立有成本，且 LaunchDaemon 常驻语义
// 下反复重连只会放大故障面。写失败不关连接（下一行请求还能试），
// 连接打不开时每个 set 都独立重试——helper 装好后无需重启即可恢复服务。
var smcConnection: io_connect_t = 0

while true {
    guard let line = readLine() else { break }  // EOF = 客户端离场，正常退出
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }

    guard let request = FanHelperProtocol.parseRequest(line: trimmed) else {
        print(FanHelperProtocol.errorJSON("请求不是合法 JSON 行或缺少 action"))
        fflush(stdout)
        continue
    }

    switch request.action {
    case "ping":
        // 零副作用握手：客户端探测"二进制在且说同一版协议"
        print(FanHelperProtocol.okJSON())
        fflush(stdout)

    case "set":
        guard let key = request.key else {
            print(FanHelperProtocol.errorJSON("set 缺 key"))
            fflush(stdout)
            continue
        }
        // 红线二执行点：白名单外任何键都是攻击面/误用，直接终止进程——
        // exit 1 让调用方明确看到"helper 拒绝"，绝不带着可疑请求继续服务
        guard FanHelperWhitelist.isAllowed(key: key) else {
            FileHandle.standardError.write(
                Data(("fanhelper: 拒绝白名单外的 SMC 键: \(key)\n").utf8)
            )
            print(FanHelperProtocol.errorJSON("键 \(key) 不在风扇域白名单（FS!/F{n}Md）"))
            fflush(stdout)
            exit(1)
        }
        guard let value = request.value, (0...16383).contains(value) else {
            print(FanHelperProtocol.errorJSON("键 \(key) 的值非法或缺席（模式须 1/2，转速须 0–16383）"))
            fflush(stdout)
            continue
        }
        if smcConnection == 0 {
            // 惰性开连接：ping/坏行不该为一个还没发生的写去碰 IOKit
            let opened = FanHelperSMC.openConnection()
            if opened.conn != 0 {
                smcConnection = opened.conn
            } else {
                print(FanHelperProtocol.errorJSON("SMC 不可用：\(opened.failure)"))
                fflush(stdout)
                continue
            }
        }
        if let failure = FanHelperSMC.write(conn: smcConnection, key: key, value: value) {
            print(FanHelperProtocol.errorJSON(failure))
        } else {
            print(FanHelperProtocol.okJSON())
        }
        fflush(stdout)

    default:
        print(FanHelperProtocol.errorJSON("未知 action: \(request.action)"))
        fflush(stdout)
    }
}

if smcConnection != 0 {
    IOServiceClose(smcConnection)
}
exit(0)
