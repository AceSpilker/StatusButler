import Foundation
import Testing
@testable import StatusButlerCore

// T-040：天气模块——三道网络纪律闸 + WMO 映射 + 单位换算 + 缓存 + 假 URLProtocol 端到端。
// 纪律：不做任何 live 外网请求；DNS 闸用注入表驱动，HTTP 层全走 MockURLProtocol。
// .serialized：MockURLProtocol.store 是进程级单例，并发跑会互相 reset/pop 桩

@Suite(.serialized) struct WeatherTests {

    // MARK: - 闸 1：URL 白名单（https + 编译期域名）

    @Test func httpsSchemeIsRequired() {
        #expect(!WeatherNetworkPolicy.validateURL(URL(string: "http://api.open-meteo.com/v1/forecast")!))
        #expect(!WeatherNetworkPolicy.validateURL(URL(string: "ftp://api.open-meteo.com/v1/forecast")!))
    }

    @Test func foreignHostsAreRejected() {
        #expect(!WeatherNetworkPolicy.validateURL(URL(string: "https://evil.example.com/v1")!))
        // 白名单域做后缀拼接的仿冒 host 不放行（精确匹配，非 hasSuffix）
        #expect(!WeatherNetworkPolicy.validateURL(URL(string: "https://api.open-meteo.com.evil.example.com/v1")!))
        // 少了 api. 前缀的同根域也不放行
        #expect(!WeatherNetworkPolicy.validateURL(URL(string: "https://open-meteo.com/v1")!))
    }

    @Test func canonicalForecastURLPassesGate() throws {
        let url = try #require(OpenMeteoProvider.forecastURL(latitude: 31.2304, longitude: 121.4737))
        #expect(WeatherNetworkPolicy.validateURL(url))
        let text = url.absoluteString
        // 参数拼写与 Open-Meteo 文档一致（daily 场景必须带 timezone=auto）
        #expect(text.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        #expect(text.contains("current=temperature_2m,weather_code"))
        #expect(text.contains("daily=temperature_2m_max,temperature_2m_min"))
        #expect(text.contains("timezone=auto"))
        #expect(text.contains("latitude=31.2304"))
        #expect(text.contains("longitude=121.4737"))
    }

    // MARK: - 闸 2：IP 公网校验（IPv4 点分）

    @Test func ipv4PrivateAndReservedRangesAreRejected() {
        let privateV4 = [
            "127.0.0.1",            // 环回
            "10.0.0.1",             // RFC1918 A
            "172.16.0.1",           // RFC1918 B 下界
            "172.31.255.255",       // RFC1918 B 上界
            "192.168.1.1",          // RFC1918 C
            "169.254.169.254",      // 链路本地（云元数据地址）
            "0.0.0.0",              // "this network" 保留
            "100.64.0.1",           // CGNAT 下界
            "100.127.255.255",      // CGNAT 上界
            "198.18.0.5",           // RFC2544 基准
            "198.51.100.7",         // RFC5737 TEST-NET-2
            "203.0.113.9",          // RFC5737 TEST-NET-3
            "192.0.2.1",            // RFC5737 TEST-NET-1
            "240.0.0.1",            // E 类保留
            "255.255.255.255",      // 广播
        ]
        for address in privateV4 {
            #expect(!WeatherNetworkPolicy.isPublicAddress(address), "应拒绝 \(address)")
        }
        // 一枚私网混进列表即整体拒绝（allSatisfy 语义）
        #expect(!WeatherNetworkPolicy.validateAddresses(["8.8.8.8", "10.0.0.1"]))
    }

    @Test func ipv4PublicAddressesPassIncludingRangeBoundaries() {
        let publicV4 = [
            "8.8.8.8", "1.1.1.1", "93.184.216.34",
            "172.15.255.255",   // 172.16/12 下界之外
            "172.32.0.1",       // 172.16/12 上界之外
            "100.63.0.1",       // CGNAT 下界之外
            "100.128.0.1",      // CGNAT 上界之外
        ]
        for address in publicV4 {
            #expect(WeatherNetworkPolicy.isPublicAddress(address), "应放行 \(address)")
        }
        #expect(WeatherNetworkPolicy.validateAddresses(publicV4))
    }

    // MARK: - 闸 2：IP 公网校验（IPv6 冒分）

    @Test func ipv6NonPublicFormsAreRejected() {
        let privateV6 = [
            "::1",                   // 环回
            "::",                    // 未指定
            "fe80::1",               // 链路本地
            "fe80:0:0:0:0:0:0:2",    // 链路本地（展开形态，字符串匹配漏、字节判定稳）
            "fd00::1",               // ULA fd
            "fc00::1",               // ULA fc
            "ff02::1",               // 组播
            "::ffff:127.0.0.1",      // v4 映射环回
            "::ffff:192.168.1.1",    // v4 映射私网
            "::10.0.0.1",            // v4 兼容（已废弃）内嵌私网
            "2002:0a00:0001::",      // 6to4 内嵌 10.0.0.1
        ]
        for address in privateV6 {
            #expect(!WeatherNetworkPolicy.isPublicAddress(address), "应拒绝 \(address)")
        }
        #expect(!WeatherNetworkPolicy.validateAddresses(["2606:4700::1111", "fd12::1"]))
    }

    @Test func ipv6PublicAddressesPass() {
        #expect(WeatherNetworkPolicy.isPublicAddress("2606:4700::1111"))
        #expect(WeatherNetworkPolicy.isPublicAddress("2a00:1450:4001:81b::200e"))
        // v4 映射的公网地址、内嵌公网 v4 的 6to4 仍放行
        #expect(WeatherNetworkPolicy.isPublicAddress("::ffff:8.8.8.8"))
        #expect(WeatherNetworkPolicy.isPublicAddress("2002:0808:0808::"))
    }

    @Test func unparseableOrEmptyAddressListsAreRejected() {
        // fail closed：解析不出 IP 的字符串（CNAME 残留/脏数据）与空表都不放行
        #expect(!WeatherNetworkPolicy.validateAddresses([]))
        #expect(!WeatherNetworkPolicy.validateAddresses(["api.open-meteo.com"]))
        #expect(!WeatherNetworkPolicy.validateAddresses(["8.8.8.8", "not-an-ip"]))
    }

    // MARK: - 闸 3：重定向 handler（直接驱动 delegate 方法）
    // 实测本运行时（macOS 26 SDK）URLSession 不再对自定义 URLProtocol 提供的 30x
    // 做重定向处理（不跟随、也不咨询 delegate），mock 桩驱动不了真重定向链路；
    // 而 handler 的全部契约就是"收到 willPerformHTTPRedirection 时如何裁决"，
    // 故用未 resume 的 dataTask 当 originalRequest 载体直接调用（全程零出网）。

    private func makeRedirectFixture() -> (session: URLSession, task: URLSessionTask, handler: WeatherNetworkPolicy.SafeRedirectHandler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: WeatherNetworkPolicy.SafeRedirectHandler(),
            delegateQueue: nil
        )
        let task = session.dataTask(with: URL(string: "https://api.open-meteo.com/v1/forecast")!)
        return (session, task, WeatherNetworkPolicy.SafeRedirectHandler())
    }

    private func redirectResponse(url: String, location: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": location]
        )!
    }

    @Test func sameHostHTTPSRedirectIsAllowed() {
        MockURLProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        let redirectedTo = "https://api.open-meteo.com/v1/forecast?step=2"
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(url: "https://api.open-meteo.com/v1/forecast", location: redirectedTo),
            newRequest: URLRequest(url: URL(string: redirectedTo)!)
        ) { forwarded = $0 }
        #expect(forwarded?.url?.absoluteString == redirectedTo)
        #expect(fixture.task.state == .suspended)  // 未取消
        #expect(MockURLProtocol.store.count == 0)
    }

    @Test func crossHostRedirectIsCancelled() {
        MockURLProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(url: "https://api.open-meteo.com/v1/forecast", location: "https://attacker.example/steal"),
            newRequest: URLRequest(url: URL(string: "https://attacker.example/steal")!)
        ) { forwarded = $0 }
        #expect(forwarded == nil)                  // 跨 host 不放行
        #expect(fixture.task.state == .canceling)  // 且主动取消任务
        #expect(MockURLProtocol.store.count == 0)  // 第二跳从未发出
    }

    @Test func sameHostHTTPDowngradeIsCancelled() {
        MockURLProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(url: "https://api.open-meteo.com/v1/forecast", location: "http://api.open-meteo.com/v1/forecast"),  // 同 host 但降级 http
            newRequest: URLRequest(url: URL(string: "http://api.open-meteo.com/v1/forecast")!)
        ) { forwarded = $0 }
        #expect(forwarded == nil)
        #expect(fixture.task.state == .canceling)
        #expect(MockURLProtocol.store.count == 0)
    }

    // MARK: - WMO 代码映射与单位换算（纯函数）

    @Test func wmoCodeBucketsMapToSymbolsAndChineseLabels() {
        // 规格（A8·WX-01）只要求主要档位；85/86 雪阵等未列入的代码归"未知"——宁缺勿错译
        let table: [(code: Int, label: String, symbol: String)] = [
            (0, "晴", "sun.max.fill"),
            (1, "多云", "cloud.sun.fill"),
            (3, "多云", "cloud.sun.fill"),
            (45, "雾", "cloud.fog.fill"),
            (48, "雾", "cloud.fog.fill"),
            (51, "雨", "cloud.rain.fill"),
            (61, "雨", "cloud.rain.fill"),
            (67, "雨", "cloud.rain.fill"),
            (71, "雪", "cloud.snow.fill"),
            (77, "雪", "cloud.snow.fill"),
            (80, "阵雨", "cloud.heavyrain.fill"),
            (82, "阵雨", "cloud.heavyrain.fill"),
            (95, "雷暴", "cloud.bolt.rain.fill"),
            (99, "雷暴", "cloud.bolt.rain.fill"),
            (85, "未知", "questionmark.circle"),
            (-1, "未知", "questionmark.circle"),
        ]
        for row in table {
            let mapped = WeatherNow.symbolism(code: row.code)
            #expect(mapped.label == row.label, "code \(row.code) 描述应为 \(row.label)")
            #expect(mapped.symbol == row.symbol, "code \(row.code) 符号应为 \(row.symbol)")
        }
    }

    @Test func celsiusToFahrenheitConversion() {
        #expect(WeatherUnits.fahrenheit(fromCelsius: 0) == 32)
        #expect(WeatherUnits.fahrenheit(fromCelsius: 100) == 212)
        #expect(WeatherUnits.fahrenheit(fromCelsius: -40) == -40)
        #expect(abs(WeatherUnits.fahrenheit(fromCelsius: 37) - 98.6) < 0.0001)
    }

    // MARK: - 缓存新鲜度与失败静默（WX-03-3）

    @Test func cacheFreshnessBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(WeatherCache.isFresh(fetchedAt: now.addingTimeInterval(-1_799), now: now, ttl: 1_800))  // ttl - 1s
        #expect(!WeatherCache.isFresh(fetchedAt: now.addingTimeInterval(-1_800), now: now, ttl: 1_800))  // 满 ttl 即过期
        #expect(!WeatherCache.isFresh(fetchedAt: now.addingTimeInterval(-1_801), now: now, ttl: 1_800))
        // 时钟回拨/小偏差（fetchedAt 略在未来）仍视为新鲜
        #expect(WeatherCache.isFresh(fetchedAt: now.addingTimeInterval(30), now: now, ttl: 1_800))
    }

    @Test func cacheKeepsLastValueForQuietFailureAfterExpiry() {
        let cache = WeatherCache()
        let base = Date(timeIntervalSince1970: 2_000_000)
        let entry = WeatherNow(temperatureC: 21.5, weatherCode: 0, dailyMaxC: 26, dailyMinC: 18, fetchedAt: base)
        #expect(cache.quietFailureText() == "暂无数据")  // 从未成功过

        cache.store(entry)
        #expect(cache.fresh(now: base.addingTimeInterval(60)) == entry)
        // 期望文案用同一 formatter 设置镜像计算（时区随本地，口径与实现一致）
        let mirror = DateFormatter()
        mirror.dateFormat = "HH:mm"
        mirror.locale = Locale(identifier: "en_US_POSIX")
        let expected = "暂无数据 · 更新于 " + mirror.string(from: base)
        #expect(cache.quietFailureText(now: base.addingTimeInterval(60)) == expected)

        // 过期后：fresh 返回 nil，但旧值保留供"上次成功时间"展示
        let later = base.addingTimeInterval(WeatherCache.ttl + 1)
        #expect(cache.fresh(now: later) == nil)
        #expect(cache.lastKnown() == entry)
        #expect(cache.quietFailureText(now: later) == expected)
    }

    // MARK: - 端到端（假 URLProtocol，绝不触真网）

    private func makeProvider(resolver: @escaping OpenMeteoProvider.AddressResolver) -> OpenMeteoProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: WeatherNetworkPolicy.SafeRedirectHandler(),
            delegateQueue: nil
        )
        return OpenMeteoProvider(session: session, resolveAddresses: resolver)
    }

    @Test func endToEndValidJSONDecodesWhitelistedFields() async {
        MockURLProtocol.store.reset()
        // 含响应里多余字段（wind_speed_10m / *_units）：验证只解码白名单字段、其余忽略
        let json = """
        {
          "latitude": 31.2, "longitude": 121.5, "timezone": "Asia/Shanghai",
          "current": { "time": "2026-10-12T14:00", "interval": 900, "temperature_2m": 22.7, "weather_code": 3, "wind_speed_10m": 999 },
          "current_units": { "temperature_2m": "°C", "weather_code": "WMO code" },
          "daily": { "time": ["2026-10-12", "2026-10-13"], "temperature_2m_max": [26.1, 25.0], "temperature_2m_min": [18.4, 17.9] },
          "daily_units": { "temperature_2m_max": "°C", "temperature_2m_min": "°C" }
        }
        """
        MockURLProtocol.store.push(host: "api.open-meteo.com", status: 200, headers: [:], body: Data(json.utf8))
        let before = Date()
        let provider = makeProvider(resolver: { _ in ["93.184.216.34"] })
        let result = await provider.fetch(latitude: 31.2304, longitude: 121.4737)
        guard case .success(let weather) = result else {
            Issue.record("期望成功，实际 \(result)")
            return
        }
        #expect(weather.temperatureC == 22.7)
        #expect(weather.weatherCode == 3)
        #expect(weather.dailyMaxC == 26.1)  // daily 数组首元素 = 今日
        #expect(weather.dailyMinC == 18.4)
        #expect(weather.fetchedAt >= before && weather.fetchedAt <= Date())
        #expect(MockURLProtocol.store.count == 1)
    }

    @Test func endToEndMalformedJSONFailsWithDecode() async {
        MockURLProtocol.store.reset()
        MockURLProtocol.store.push(host: "api.open-meteo.com", status: 200, headers: [:], body: Data("{ not json".utf8))
        let provider = makeProvider(resolver: { _ in ["93.184.216.34"] })
        let result = await provider.fetch(latitude: 0, longitude: 0)
        #expect(result == .failure(.decode))
    }

    @Test func endToEndMissingCurrentKeyFailsWithDecode() async {
        MockURLProtocol.store.reset()
        // 合法 JSON 但缺 current 白名单字段 → 不降级不猜测，按 decode 失败处理
        MockURLProtocol.store.push(host: "api.open-meteo.com", status: 200, headers: [:], body: Data("{\"daily\":{}}".utf8))
        let provider = makeProvider(resolver: { _ in ["93.184.216.34"] })
        let result = await provider.fetch(latitude: 0, longitude: 0)
        #expect(result == .failure(.decode))
    }

    @Test func endToEndPrivateDNSAnswerBlocksBeforeAnyRequest() async {
        MockURLProtocol.store.reset()
        // 仿 DNS 劫持：白名单域解析出内网地址。桩里故意放 200 成功体，
        // 若闸 2 失效测试将拿到 success 从而失败
        MockURLProtocol.store.push(host: "api.open-meteo.com", status: 200, headers: [:], body: Data("should-never-load".utf8))
        let provider = makeProvider(resolver: { _ in ["192.168.1.1"] })
        let result = await provider.fetch(latitude: 31.2, longitude: 121.5)
        #expect(result == .failure(.blockedAddress))
        // 关键纪律：请求根本没发出去（闸 2 在 data(for:) 之前）
        #expect(MockURLProtocol.store.count == 0)
    }

    @Test func endToEndMixedDNSAnswerWithOnePrivateIPBlocks() async {
        MockURLProtocol.store.reset()
        // 公网 + 私网混排（劫持场景常见：真地址里掺一枚内网）→ 整体拒绝
        let provider = makeProvider(resolver: { _ in ["2606:4700::1111", "10.0.0.5"] })
        let result = await provider.fetch(latitude: 31.2, longitude: 121.5)
        #expect(result == .failure(.blockedAddress))
        #expect(MockURLProtocol.store.count == 0)
    }

    @Test func endToEndHTTPErrorMapsToNetwork() async {
        MockURLProtocol.store.reset()
        MockURLProtocol.store.push(host: "api.open-meteo.com", status: 503, headers: [:], body: Data())
        let provider = makeProvider(resolver: { _ in ["93.184.216.34"] })
        let result = await provider.fetch(latitude: 31.2, longitude: 121.5)
        #expect(result == .failure(.network("HTTP 503")))
    }

    @Test func endToEnd302SurfacesAsNetworkErrorWithoutFollowing() async {
        MockURLProtocol.store.reset()
        MockURLProtocol.store.push(
            host: "api.open-meteo.com", status: 302,
            headers: ["Location": "https://attacker.example/steal"],
            body: Data()
        )
        let provider = makeProvider(resolver: { _ in ["93.184.216.34"] })
        let result = await provider.fetch(latitude: 31.2, longitude: 121.5)
        // 本运行时 URLSession 不跟随桩 302 → 非 2xx 直接映射 network，攻击域零请求；
        // 若未来运行时开始自动跟随重定向，provider 会话已装 SafeRedirectHandler，
        // 跨 host 跳转会被闸 3 取消并上浮 cancelled
        #expect(result == .failure(.network("HTTP 302")))
        #expect(MockURLProtocol.store.count == 1)
    }

    // MARK: - getaddrinfo 包装冒烟（不出外网：localhost 走 /etc/hosts）

    @Test func resolverReadsLoopbackFromHostsFile() {
        let addresses = WeatherNetworkPolicy.resolveHost("localhost")
        // 解析环境异常（无 hosts 行）则跳过——沿用本仓 live 冒烟的宽容口径
        guard !addresses.isEmpty else { return }
        #expect(addresses.contains { $0 == "127.0.0.1" || $0 == "::1" })
        // 环回必须被闸 2 拒绝：证明"解析出来的地址"真的流经了校验
        #expect(!WeatherNetworkPolicy.validateAddresses(addresses))
    }
}

// MARK: - 假 URLProtocol（桩路由，绝不触真网）

/// 按 host 维护 FIFO 桩队列；记录每次请求 URL 供"从未发出"断言。
/// Swift 6 禁裸 static var：可变态集中进锁保护的 Store
final class MockURLProtocol: URLProtocol {
    typealias Stub = (status: Int, headers: [String: String], body: Data)

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [Stub]] = [:]
        private var seen: [URL] = []

        func reset() {
            lock.withLock { queues = [:]; seen = [] }
        }

        func push(host: String, status: Int, headers: [String: String], body: Data) {
            lock.withLock { queues[host, default: []].append((status, headers, body)) }
        }

        func pop(host: String?) -> Stub? {
            lock.withLock {
                guard let host, !queues[host, default: []].isEmpty else { return nil }
                return queues[host]?.removeFirst()
            }
        }

        func record(_ url: URL) {
            lock.withLock { seen.append(url) }
        }

        var count: Int { lock.withLock { seen.count } }
    }

    static let store = Store()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.store.record(request.url ?? URL(fileURLWithPath: "/unknown"))
        // 无桩命中 → 500 空体（宁可失败也不让 URLProtocol 落到真网络）
        let stub: Stub = Self.store.pop(host: request.url?.host(percentEncoded: false))
            ?? (status: 500, headers: [:], body: Data())
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
