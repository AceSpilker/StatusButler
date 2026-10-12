// T-023b 配件电源报告源：IOBluetooth 公开 API 不暴露每设备电量（缺口已在 BluetoothMonitor.swift 注释交接），
// 落地路径是 /usr/bin/pmset -g ps 的配件行——macOS 把在线蓝牙外设的电量混编在电源报告里。
// 解析全部纯函数：无蓝牙/无配件的机器（CI、台式）拿空表，取源失败也不让监控路径报错。

import Foundation

/// AirPods 三仓位电量：pmset 把左右耳与充电盒拆成独立 "Left/Right/Case: N%" 行，此处聚合回一个整体
public struct AirPodsBattery: Sendable, Equatable {
    public let left: Int
    public let right: Int
    /// 充电盒电量；耳机不在盒内时系统不上报——缺盒是常态而非异常
    public let `case`: Int?

    public init(left: Int, right: Int, `case`: Int? = nil) {
        self.left = left
        self.right = right
        self.`case` = `case`
    }

    /// min 显示策略：按最差仓位显示，任一仓先耗尽都能被提前看见，
    /// 避免"整体 80% 实则左耳 10%"的误读
    public var percent: Int {
        if let casePercent = `case` {
            return min(left, min(right, casePercent))
        }
        return min(left, right)
    }
}

/// 配件电源报告源：跑 pmset 解析出"配件名→电量"表。表里没有地址与连接态——那半边字段由
/// BatteryMerge 从 IOBluetooth 设备清单补齐，两源各缺一半是本域的常态。
public struct AccessoryBatterySource: Sendable {
    private let collect: CommandOutputProvider

    public init(collect: CommandOutputProvider? = nil) {
        // 只读白名单：/usr/bin/pmset -g ps 是编译期常量的状态查询命令，无用户输入、不改变任何系统
        // 状态（与 HealthChecks 的 SystemCommand 同源纪律）；测试注入假实现，零系统依赖可全链路验证
        self.collect = collect ?? { try SystemCommand.stdout(path: "/usr/bin/pmset", arguments: ["-g", "ps"]) }
    }

    public func read() async -> [String: Int] {
        // pmset 是阻塞子进程往返，折进 detached 任务别占调用方协作线程（与 BluetoothMonitor 同一姿势）
        await Task.detached(priority: .utility) {
            // 命令失败（pmset 缺失/受限的极端环境）按无配件收敛，监控路径不因取源失败而抛错
            guard let stdout = try? self.collect() else { return [:] }
            return Self.parse(stdout: stdout)
        }.value
    }

    /// 纯函数：pmset -g ps stdout → 配件名→电量表。
    /// 支持的行形态：单配件 "Magic Mouse: 88%"；AirPods 分体 "Left: 88% Right: 76% Case: 55%"
    /// （各仓位独占一行时进表后形态一致，无需区分）。内置电池行与无法配对的行跳过；无配件返回空表。
    public static func parse(stdout: String) -> [String: Int] {
        var table: [String: Int] = [:]
        // "Name: N%" 配对；数字放宽到 1-3 位再由 0...100 收口，"150%" 这类越界值当异常丢弃
        let pairPattern = /([^:]+?)\s*:\s*(\d{1,3})%/
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 内置电池行（" -InternalBattery-0 (id=…) 85%; discharging…"）的百分比属于 Mac 本机，
            // 显式排除而非赌格式不撞车——pmset 措辞变化也绝不把本机电量混进配件表
            if trimmed.contains("InternalBattery") { continue }
            for match in trimmed.matches(of: pairPattern) {
                let name = match.1.trimmingCharacters(in: .whitespaces)
                guard let percent = Int(match.2), (0...100).contains(percent), !name.isEmpty else { continue }
                table[name] = percent
            }
        }
        return table
    }

    /// 纯函数：从电量表聚合 AirPods 三仓位。双耳必须齐——缺一边构不成可信的整体读数，返回 nil
    /// 交由合并层降级处理；盒电量可缺。
    public static func airPods(from levels: [String: Int]) -> AirPodsBattery? {
        func pod(_ key: String) -> Int? {
            levels.first { $0.key.lowercased() == key }?.value
        }
        guard let left = pod("left"), let right = pod("right") else { return nil }
        return AirPodsBattery(left: left, right: right, case: pod("case"))
    }
}
