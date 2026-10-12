import CoreFoundation
import Foundation

// T-053 iDevice 电量读取（代码半场）：iPhone/iPad/Watch 经 USB 直连时，macOS 公开 API
// （IOKit 的 AppleDeviceManagement 域）不暴露第三方电量——落地路径是社区标准
// libimobiledevice 工具链，但它是 C/autotools 生态，直接进 SwiftPM 会污染构建图。
// 因此拆成独立 helper 子进程（scripts/build-mobile-battery-helper.sh 源码构建，产物
// .build/mobile-battery/statusbutler-mobilebattery），主程序只消费它的 stdout。
// License 边界同理：libimobiledevice 系 LGPL 动态库全部关在 helper 进程内，
// 主程序零链接零分发责任（发布链组包由 T-053b 接手）。
//
// helper 契约（本半场钉死，C 侧实现是 T-053b 交付物）：
//   - 无参数执行，stdout 每行一个 JSON 对象，跑完 exit 0：
//     {"name":"…","udid":"…","kind":"iPhone|iPad|Watch","batteryPercent":72,"charging":true}
//   - batteryPercent/charging 可省略（Watch 经 companion_proxy 读电量常失败，
//     设备仍要出现在面板里，只是没有读数）；无设备时输出为空。
//   - 主程序对 helper 的信任度等同于本仓库自己的构建产物，但解析仍然逐行容错——
//     坏行跳过不连坐，字段类型防御不崩溃。

/// iDevice 种类：与 helper 契约里的 kind 字符串一一对应（严格匹配，不猜别名）
public enum MobileBatteryDeviceKind: String, Equatable, Sendable, Codable {
    case iPhone = "iPhone"
    case iPad = "iPad"
    case watch = "Watch"
}

/// 一台 iDevice 的电量行（值类型，可跨并发域）
public struct MobileBatteryDevice: Equatable, Sendable, Codable {
    /// 设备名；helper 读不到时折叠为 kind 名（"iPhone"），"未命名"文案归展示层
    public let name: String
    /// usbmuxd 设备唯一键，也是面板行的去重键
    public let udid: String
    public let kind: MobileBatteryDeviceKind
    /// 电量 0-100；nil = 本次没读到（Watch 常态），绝不编造哨兵值
    public let batteryPercent: Int?
    public let charging: Bool?

    public init(
        name: String,
        udid: String,
        kind: MobileBatteryDeviceKind,
        batteryPercent: Int? = nil,
        charging: Bool? = nil
    ) {
        self.name = name
        self.udid = udid
        self.kind = kind
        self.batteryPercent = batteryPercent
        self.charging = charging
    }
}

/// helper 可用性：available = 二进制在且上一轮执行成功；unavailable = 没构建/执行失败。
/// 面板据此选"电量列表"还是"引导构建 helper"的展示，而不是报错
public enum MobileBatteryHelperStatus: Equatable, Sendable {
    case available
    case unavailable
}

/// 一轮读取的结果：设备清单 + helper 可用性（缺失/失败时设备恒为空数组）
public struct MobileBatteryReading: Equatable, Sendable {
    public let status: MobileBatteryHelperStatus
    public let devices: [MobileBatteryDevice]

    public init(status: MobileBatteryHelperStatus, devices: [MobileBatteryDevice]) {
        self.status = status
        self.devices = devices
    }

    public static let unavailable = MobileBatteryReading(status: .unavailable, devices: [])
}

/// iDevice 电量读取器：执行 helper 子进程并解析其 JSON 行输出。
/// 采样纪律（能效铁律）归调用方——本类型只是取数源，面板旁路"有人看才运行"的
/// 启停接线在 MobileBatterySlot / 面板层（T-053b），常驻轮询是被禁止的使用方式。
public struct MobileBatteryHelperReader: Sendable {
    /// 开发期默认路径（swift run/测试从包根起跑，CWD 即包根）；
    /// 组包后由组合根注入 .app 内 helper 的绝对路径——相对路径只对开发态有意义
    public static let defaultHelperPath = ".build/mobile-battery/statusbutler-mobilebattery"

    public let helperPath: String

    /// 子进程执行器：路径 → stdout。默认真实实现；测试注入假闭包零系统依赖全链路验证
    private let collect: @Sendable (_ path: String) throws -> String

    public init(
        helperPath: String = MobileBatteryHelperReader.defaultHelperPath,
        collect: (@Sendable (_ path: String) throws -> String)? = nil
    ) {
        // helper 是本仓库构建产物、零参数调用，不存在把用户输入拼进命令行的面
        // （HealthChecks 的 SystemCommand 同源纪律）；非零退出码按"本轮不可用"收敛
        self.helperPath = helperPath
        self.collect = collect ?? { path in
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try SystemCommand.stdout(path: path, arguments: [])
        }
    }

    public func read() async -> MobileBatteryReading {
        // helper 往返是阻塞子进程，折进 detached 任务别占调用方协作线程
        // （与 AccessoryBatterySource 同一姿势）；超时治理归接线层（T-053b），
        // helper 契约本身就是短命单发进程
        await Task.detached(priority: .utility) {
            guard let stdout = try? self.collect(self.helperPath) else {
                return MobileBatteryReading.unavailable
            }
            return MobileBatteryReading(status: .available, devices: Self.parse(stdout: stdout))
        }.value
    }

    /// 纯函数：helper stdout（JSON 行）→ 设备清单。
    /// 容错边界：非法 JSON 行、非对象行、缺 udid、kind 不在三种之列——跳过该行不连坐；
    /// 同一 udid 多行（USB/网络双通道重复上报）取第一行；batteryPercent/charging
    /// 接受数字/字符串/布尔的防御性形态，越界（>100）与无法理解的值按"没读到"折叠为 nil
    public static func parse(stdout: String) -> [MobileBatteryDevice] {
        var devices: [MobileBatteryDevice] = []
        var seen: Set<String> = []
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let device = device(fromJSONObject: object),
                  seen.insert(device.udid).inserted
            else { continue }
            devices.append(device)
        }
        return devices
    }

    /// 单行 → 设备：udid 与 kind 是硬字段（缺/空/未知 → 整行丢弃），
    /// name 缺失时退到 kind 名而不是丢设备——"看到手表在读数外"仍有面板价值
    private static func device(fromJSONObject object: [String: Any]) -> MobileBatteryDevice? {
        guard let udid = object["udid"] as? String,
              !udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let kindRaw = object["kind"] as? String,
              let kind = MobileBatteryDeviceKind(rawValue: kindRaw)
        else { return nil }
        let name = (object["name"] as? String).flatMap { trimmed($0) } ?? kind.rawValue
        return MobileBatteryDevice(
            name: name,
            udid: udid,
            kind: kind,
            batteryPercent: percent(from: object["batteryPercent"]),
            charging: chargingFlag(from: object["charging"])
        )
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 电量防御性取值：JSONSerialization 把数字给成 NSNumber——Foundation 的 Bool 桥接
    /// 会把 1/0 当 true/false，先按 CFBoolean 类型分流再谈数值；小数取四舍五入
    /// （C 侧 plist REAL 可能带小数），越界值（150 / -3）当"没读到"而非截断编造
    private static func percent(from value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let candidate = Int(number.doubleValue.rounded())
            return (0...100).contains(candidate) ? candidate : nil
        }
        if let text = value as? String {
            let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = digits.hasSuffix("%") ? String(digits.dropLast()) : digits
            guard let candidate = Int(bare) else { return nil }
            return (0...100).contains(candidate) ? candidate : nil
        }
        return nil
    }

    /// 充电态防御性取值：真布尔直取；数值按 1/0；字符串认 true/false/yes/no/1/0
    /// （大小写不敏感）——其余（"charging"、2、数组）当"没读到"
    private static func chargingFlag(from value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            switch number.intValue {
            case 1: return true
            case 0: return false
            default: return nil
            }
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
