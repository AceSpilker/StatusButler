import Testing
@testable import StatusButlerCore

// T-024: path 原始信号 → ConnectionDetails 纯映射（假数据注入；live NWPathMonitor 只在冒烟里碰）
@Suite struct NetworkConnectionMonitorTests {
    @Test func wifiSatisfiedIsPlainOnline() {
        let details = NetworkConnectionMonitor.details(
            isSatisfied: true, isExpensive: false, isConstrained: false,
            interfaceNames: ["en0"], types: [.wifi]
        )
        #expect(details == ConnectionDetails(
            isSatisfied: true, isExpensive: false, isConstrained: false,
            isVPN: false, interfaceTypes: [.wifi]
        ))
    }

    @Test func utunOtherInterfaceMarksVPN() {
        let details = NetworkConnectionMonitor.details(
            isSatisfied: true, isExpensive: false, isConstrained: false,
            interfaceNames: ["en0", "utun3"], types: [.wifi, .other]
        )
        #expect(details.isVPN)
        #expect(details.interfaceTypes == [.wifi, .other])
    }

    @Test func nonUtunOtherInterfaceIsNotVPN() {
        // awdl0（AWDL 点对点）同为 .other，但非隧道——前缀过滤防误报
        let details = NetworkConnectionMonitor.details(
            isSatisfied: true, isExpensive: false, isConstrained: false,
            interfaceNames: ["en0", "awdl0"], types: [.wifi, .other]
        )
        #expect(!details.isVPN)
    }

    @Test func constrainedNetworkFlagged() {
        let details = NetworkConnectionMonitor.details(
            isSatisfied: true, isExpensive: false, isConstrained: true,
            interfaceNames: ["en0"], types: [.wifi]
        )
        #expect(details.isConstrained)
        #expect(details.isSatisfied)
    }

    @Test func offlineHasNoInterfaces() {
        let details = NetworkConnectionMonitor.details(
            isSatisfied: false, isExpensive: false, isConstrained: false,
            interfaceNames: [], types: []
        )
        #expect(details == .offline)
        #expect(!details.isVPN)
    }

    @Test func expensiveCellularHotspotFlagged() {
        let details = NetworkConnectionMonitor.details(
            isSatisfied: true, isExpensive: true, isConstrained: false,
            interfaceNames: ["bridge100"], types: [.other]
        )
        #expect(details.isExpensive)
        #expect(!details.isVPN)  // bridge 接口（互联网共享）不是 utun
    }

    @Test func liveReadSmoke() async {
        let monitor = NetworkConnectionMonitor()
        // 等 monitor 首个 path 回调（完全离线的机器会一直保持初值，同样合法）
        for _ in 0..<40 where await monitor.read() == .offline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let details = await monitor.read()
        if details.isSatisfied {
            // 满足的 path 至少挂在一块接口上
            #expect(!details.interfaceTypes.isEmpty)
        }
        if details.isVPN {
            // utun 必然以 .other 类型出现
            #expect(details.interfaceTypes.contains(.other))
        }
    }
}
