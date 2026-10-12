import Foundation

// MARK: - 模型（T-027）

public struct NetRates: Sendable, Equatable {
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double

    public init(bytesInPerSec: Double, bytesOutPerSec: Double) {
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
    }
}

// MARK: - 监控器

/// 网速一次性采样器：sysctl(NET_RT_IFLIST2) 各接口字节计数器两次差分 ÷ 真实时钟间隔。
/// 排除回环 lo0（A7·PF-01：回环接口不计速）。
/// 采样纪律（A7·3）：仅被调用时读两次各一次，无循环无定时器——"有人看才采样"。
public struct NetRateMonitor: Sendable {
    /// 差分窗口：配合真实时钟差做分母；100ms 让低速场景计数器也能翻动几位
    public static let sampleWindow: Duration = .milliseconds(100)

    public init() {}

    public func read() async -> NetRates? {
        let clock = ContinuousClock()
        guard let prev = Self.interfaceTotals() else { return nil }
        let start = clock.now
        try? await Task.sleep(for: Self.sampleWindow)
        // 用真实流逝时间做分母：sleep 被取消/调度延迟时速率仍正确
        let interval = Self.seconds(from: clock.now - start)
        guard let curr = Self.interfaceTotals() else { return nil }
        let rates = Self.rates(prev: prev, curr: curr, interval: interval)
        return NetRates(bytesInPerSec: rates.bytesInPerSec, bytesOutPerSec: rates.bytesOutPerSec)
    }

    // MARK: - 纯函数（单测入口）

    /// 计数器差分 → 速率。间隔 ≤ 0 防除零按 0 处理；
    /// 计数器回绕/接口在窗口内消失（curr<prev）饱和为 0，不产生负速率。
    public static func rates(
        prev: (in: UInt64, out: UInt64),
        curr: (in: UInt64, out: UInt64),
        interval: TimeInterval
    ) -> NetRates {
        guard interval > 0 else { return NetRates(bytesInPerSec: 0, bytesOutPerSec: 0) }
        let deltaIn = curr.in >= prev.in ? Double(curr.in - prev.in) : 0
        let deltaOut = curr.out >= prev.out ? Double(curr.out - prev.out) : 0
        return NetRates(bytesInPerSec: deltaIn / interval, bytesOutPerSec: deltaOut / interval)
    }

    /// 遍历 NET_RT_IFLIST2 报文，累加除 lo0 外全部接口的 ifi_ibytes/ifi_obytes。
    /// 纯函数：喂合成报文即可单测 lo0 排除逻辑。结构非法的消息整条跳过（保守丢弃）。
    static func sumInterfaceTotals(bytes: [UInt8]) -> (in: UInt64, out: UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        let headerSize = MemoryLayout<if_msghdr2>.size
        var offset = 0
        while offset + headerSize <= bytes.count {
            let header = bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }
            let messageLength = Int(header.ifm_msglen)
            guard messageLength >= headerSize, offset + messageLength <= bytes.count else { break }
            if header.ifm_type == UInt8(RTM_IFINFO2) {
                let name = interfaceName(bytes: bytes, messageStart: offset, messageEnd: offset + messageLength, headerSize: headerSize, addrs: header.ifm_addrs)
                // 名字解析不出的接口整条跳过：身份不明的流量宁少勿错算
                if let name, name != "lo0" {
                    totalIn += header.ifm_data.ifi_ibytes
                    totalOut += header.ifm_data.ifi_obytes
                }
            }
            offset += messageLength
        }
        return (totalIn, totalOut)
    }

    /// 从 RTM_IFINFO2 消息头后的 sockaddr_dl 取接口名。
    /// sockaddr_dl 逐字节读而不是整结构 load：真实报文按 sdl_len 紧凑排布，
    /// 尾部不足 sizeof(sockaddr_dl) 时整结构 load 会越界。结构非法返回 nil。
    private static func interfaceName(
        bytes: [UInt8],
        messageStart: Int,
        messageEnd: Int,
        headerSize: Int,
        addrs: Int32
    ) -> String? {
        guard addrs & Int32(RTA_IFP) != 0 else { return nil }
        let sdlOffset = messageStart + headerSize
        // sockaddr_dl 前 8 字节：len/family/index(2)/type/nlen/alen/slen
        guard sdlOffset + 8 <= messageEnd,
              bytes[sdlOffset + 1] == UInt8(AF_LINK)
        else { return nil }
        let nameLength = Int(bytes[sdlOffset + 6])
        guard nameLength > 0, sdlOffset + 8 + nameLength <= messageEnd else { return nil }
        return String(bytes: bytes[(sdlOffset + 8)..<(sdlOffset + 8 + nameLength)], encoding: .utf8)
    }

    static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: - 系统读取

    /// 一次 sysctl 拿全部接口字节计数器总和（阻塞调用收敛于此，read() 只编排）
    nonisolated static func interfaceTotals() -> (in: UInt64, out: UInt64)? {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_INET, NET_RT_IFLIST2, 0]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0, needed > 0 else { return nil }
        let available = min(needed, buffer.count)
        return sumInterfaceTotals(bytes: Array(buffer[0..<available]))
    }
}
