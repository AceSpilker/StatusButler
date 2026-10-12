import Foundation
import Testing
@testable import StatusButlerCore

// T-027: 网速差分纯函数 + IFLIST2 报文遍历（合成报文验证 lo0 排除）+ live 冒烟
@Suite struct NetRateMonitorTests {
    @Test func knownDeltasProduceExactRates() {
        // Δin=2000B, Δout=500B, 间隔 2s → 1000 / 250 B/s
        let rates = NetRateMonitor.rates(
            prev: (in: 1000, out: 500), curr: (in: 3000, out: 1000), interval: 2
        )
        #expect(rates.bytesInPerSec == 1000)
        #expect(rates.bytesOutPerSec == 250)
    }

    @Test func fractionalIntervalDividesCorrectly() {
        // 250ms 窗口 Δ 100B → 400 B/s（真实采样走亚秒间隔）
        let rates = NetRateMonitor.rates(
            prev: (in: 0, out: 0), curr: (in: 100, out: 0), interval: 0.25
        )
        #expect(rates.bytesInPerSec == 400)
        #expect(rates.bytesOutPerSec == 0)
    }

    @Test func zeroIntervalGuardsAgainstDivisionByZero() {
        let rates = NetRateMonitor.rates(
            prev: (in: 0, out: 0), curr: (in: 500, out: 500), interval: 0
        )
        #expect(rates.bytesInPerSec == 0)
        #expect(rates.bytesOutPerSec == 0)
    }

    @Test func counterResetSaturatesToZero() {
        // 接口消失/回绕（curr<prev）→ 0，不产生负速率
        let rates = NetRateMonitor.rates(
            prev: (in: 9000, out: 9000), curr: (in: 100, out: 100), interval: 1
        )
        #expect(rates.bytesInPerSec == 0)
        #expect(rates.bytesOutPerSec == 0)
    }

    // MARK: - IFLIST2 报文遍历（纯函数，合成报文）

    @Test func synthesizedInterfaceListExcludesLoopback() throws {
        var buffer: [UInt8] = []
        buffer.append(contentsOf: Self.record(name: "lo0", inBytes: 1000, outBytes: 2000))
        buffer.append(contentsOf: Self.record(name: "en0", inBytes: 3000, outBytes: 4000))
        buffer.append(contentsOf: Self.record(name: "utun4", inBytes: 50, outBytes: 60))
        let totals = NetRateMonitor.sumInterfaceTotals(bytes: buffer)
        // lo0 的 1000/2000 不计入
        #expect(totals.in == 3050)
        #expect(totals.out == 4060)
    }

    @Test func emptyAndGarbageBuffersYieldZeroTotals() {
        #expect(NetRateMonitor.sumInterfaceTotals(bytes: []) == (in: 0, out: 0))
        // 截断的报文（msglen 越界）按 break 处理，不崩溃不误加
        #expect(NetRateMonitor.sumInterfaceTotals(bytes: [0xFF, 0xFF, 0x00, 0x00]) == (in: 0, out: 0))
    }

    @Test func recordWithoutIFPSockaddrIsSkipped() {
        // ifm_addrs 无 RTA_IFP 位：取不到名字，保守丢弃（宁少勿错算）
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_addrs = 0
        header.ifm_data.ifi_ibytes = 777
        header.ifm_data.ifi_obytes = 888
        let bytes = withUnsafeBytes(of: header) { [UInt8]($0) }
        #expect(NetRateMonitor.sumInterfaceTotals(bytes: bytes) == (in: 0, out: 0))
    }

    @Test func durationConvertsToSeconds() {
        #expect(NetRateMonitor.seconds(from: .seconds(2)) == 2)
        #expect(NetRateMonitor.seconds(from: .milliseconds(250)) == 0.25)
    }

    /// 合成一条 RTM_IFINFO2 报文：if_msghdr2 + sockaddr_dl（名字放 sdl_data，前 8 字节是定长头）
    private static func record(name: String, inBytes: UInt64, outBytes: UInt64) -> [UInt8] {
        var header = if_msghdr2()
        var link = [UInt8](repeating: 0, count: MemoryLayout<sockaddr_dl>.size)
        let nameBytes = Array(name.utf8)
        link[0] = UInt8(8 + nameBytes.count)  // sdl_len
        link[1] = UInt8(AF_LINK)              // sdl_family
        link[6] = UInt8(nameBytes.count)      // sdl_nlen
        for (i, b) in nameBytes.enumerated() { link[8 + i] = b }

        let headerSize = MemoryLayout<if_msghdr2>.size
        header.ifm_msglen = UInt16(headerSize + link.count)
        header.ifm_version = 5  // RTM_VERSION
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_addrs = Int32(RTA_IFP)
        header.ifm_data.ifi_ibytes = inBytes
        header.ifm_data.ifi_obytes = outBytes

        var bytes = withUnsafeBytes(of: header) { [UInt8]($0) }
        bytes.append(contentsOf: link)
        return bytes
    }

    // MARK: - live 冒烟（无流量/无网卡的机器上只验非负与有限性）

    @Test func liveReadReturnsFiniteRatesOrNull() async {
        guard let rates = await NetRateMonitor().read() else { return }
        #expect(rates.bytesInPerSec >= 0 && rates.bytesInPerSec.isFinite)
        #expect(rates.bytesOutPerSec >= 0 && rates.bytesOutPerSec.isFinite)
    }

    @Test func liveInterfaceTotalsMonotonicOrNull() {
        guard let first = NetRateMonitor.interfaceTotals() else { return }
        guard let second = NetRateMonitor.interfaceTotals() else { return }
        // 计数器单调；两次紧邻读取差值小（越界说明解析错位）
        #expect(second.in >= first.in)
        #expect(second.out >= first.out)
        #expect(second.in - first.in < 1 << 30)
    }
}
