import Testing
@testable import StatusButlerCore

// T-021: 信号 4 级映射逐门限钉边界（±1 防差一错误）+ 真机拉取冒烟
@Suite struct WiFiMonitorTests {
    // 门限与级别的对照表：任务规格 >=-55→4 / >=-65→3 / >=-75→2 / >=-85→1 / 其余 0
    private static let thresholds: [(rssi: Int, bars: Int)] = [
        (-55, 4), (-65, 3), (-75, 2), (-85, 1),
    ]

    @Test func signalBarsAtExactThresholds() {
        for t in Self.thresholds {
            #expect(WiFiMonitor.signalBars(rssi: t.rssi) == t.bars,
                    "门限点 \(t.rssi) 应取上限级别 \(t.bars)")
        }
    }

    @Test func signalBarsOneAboveEachThreshold() {
        for t in Self.thresholds {
            #expect(WiFiMonitor.signalBars(rssi: t.rssi + 1) == t.bars,
                    "门限 +1（信号更强）不应降级")
        }
    }

    @Test func signalBarsOneBelowEachThreshold() {
        for t in Self.thresholds {
            #expect(WiFiMonitor.signalBars(rssi: t.rssi - 1) == t.bars - 1,
                    "门限 -1（信号更弱）应降一级")
        }
    }

    @Test func signalBarsExtremes() {
        #expect(WiFiMonitor.signalBars(rssi: 0) == 4)
        #expect(WiFiMonitor.signalBars(rssi: -30) == 4)
        #expect(WiFiMonitor.signalBars(rssi: -86) == 0)
        #expect(WiFiMonitor.signalBars(rssi: -100) == 0)
    }

    // 真机冒烟：不断言具体信号值（依赖运行环境），只钉不变量——
    // 不崩溃；电源开时必为 .wifi 且格数 0-4；SSID 无定位授权时合法为 nil
    @Test func liveReadReturnsCoherentLink() async {
        let monitor = WiFiMonitor()
        let link = await monitor.read()
        switch link {
        case .offline, .wired:
            break
        case let .wifi(ssid, bars):
            #expect((0...4).contains(bars))
            #expect(ssid == nil || !ssid!.isEmpty)
        }
        // 并发两次读取验证串行队列没有把 CoreWLAN 打爆
        async let first = monitor.read()
        async let second = monitor.read()
        _ = await (first, second)
    }
}
