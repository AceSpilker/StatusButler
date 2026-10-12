import Foundation
import Testing
@testable import StatusButlerCore

// T-055a：遥测引擎——键集钉死 / 资格矩阵 / 24h 节流边界 / installID 持久化 /
// 发送引擎三道闸（假 URLProtocol 端到端）/ 调度器 tick。
// 纪律：不做任何 live 外网请求；DNS 闸注入表驱动，HTTP 层全走 TelemetryStubProtocol。
// .serialized：桩 store 是进程级单例，套件内并发跑会互相 reset/pop 桩；
// 不复用 WeatherTests 的 MockURLProtocol——它是另一套件的单例，跨套件无同步会踩桩

// MARK: - 策略纯函数（默认关 / 节流 / installID）

@Suite struct TelemetryPolicyTests {

    @Test func sendEligibilityIsOptedInProductionReachableOnly() {
        // consent 三态 × debug 两态 × 网络两态全组合（12 格）：唯一放行格 = optedIn + 生产 + 可达
        for consent in TelemetryConsent.allCases {
            for isDebug in [false, true] {
                for reachable in [false, true] {
                    let expected = consent == .optedIn && !isDebug && reachable
                    #expect(
                        TelemetryPolicy.shouldSend(
                            consent: consent, isDebugBuild: isDebug, networkReachable: reachable
                        ) == expected,
                        "组合 \(consent)/debug=\(isDebug)/net=\(reachable) 判定错误"
                    )
                }
            }
        }
    }

    @Test func throttleBoundaryAround24Hours() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(TelemetryPolicy.isDue(lastSentAt: nil, now: now))                          // 从未发过 → 到期
        #expect(!TelemetryPolicy.isDue(lastSentAt: now.addingTimeInterval(-23.9 * 3600), now: now))  // 23.9h 不发
        #expect(TelemetryPolicy.isDue(lastSentAt: now.addingTimeInterval(-24.1 * 3600), now: now))   // 24.1h 发
        // 满 24h 整点即到期（与 WeatherCache "满 TTL 即过期"对称口径）
        #expect(TelemetryPolicy.isDue(lastSentAt: now.addingTimeInterval(-24 * 3600), now: now))
        // 时钟回拨（lastSentAt 落在未来）不算到期，防同一天重复发送
        #expect(!TelemetryPolicy.isDue(lastSentAt: now.addingTimeInterval(3600), now: now))
    }

    @Test func installationIDIsStableAcrossReadsAndInstances() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = TelemetryPolicy.installationID(defaults: defaults)
        #expect(TelemetryPolicy.installationID(defaults: defaults) == first)
        // 落盘形态是可复原的 UUID 字符串
        let raw = try #require(defaults.string(forKey: TelemetryPolicy.installationIDKey))
        #expect(UUID(uuidString: raw) == first)
        // 跨实例（同 suite 重新打开）仍稳定——"随机安装 ID"的生命周期是安装而非进程
        let reloaded = UserDefaults(suiteName: suite)!
        #expect(TelemetryPolicy.installationID(defaults: reloaded) == first)
    }

    @Test func installationIDRegeneratesAfterCorruption() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set("not-a-uuid", forKey: TelemetryPolicy.installationIDKey)
        let regenerated = TelemetryPolicy.installationID(defaults: defaults)
        // 脏值按首读处理：生成新 UUID 并覆写落盘
        #expect(UUID(uuidString: "not-a-uuid") == nil)
        #expect(defaults.string(forKey: TelemetryPolicy.installationIDKey) == regenerated.uuidString)
        #expect(TelemetryPolicy.installationID(defaults: defaults) == regenerated)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

// MARK: - 心跳载荷（键集钉死 + 纯生成器）

@Suite struct TelemetryHeartbeatTests {

    private func sampleHeartbeat(placement: AppIconPlacement = .dockOnly) -> TelemetryHeartbeat {
        TelemetryHeartbeat.make(
            installationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            appVersion: "0.1.0",
            osVersion: "15.0.0",
            language: "zh-Hans",
            iconPlacement: placement,
            sentAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    @Test func codableKeySetIsPinnedToExactPayload() throws {
        let heartbeat = sampleHeartbeat()
        let data = try JSONEncoder().encode(heartbeat)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // S11 最小化：键集即全部 payload——多一键少一键都是隐私文档违约，本断言钉死
        #expect(
            Set(json.keys) == ["installationID", "appVersion", "osVersion", "language", "iconPlacement", "sentAt"]
        )
        #expect(json["installationID"] as? String == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(json["iconPlacement"] as? String == "dockOnly")  // 枚举存 rawValue，不进本地类型
        #expect(json["language"] as? String == "zh-Hans")
        #expect(json.values.allSatisfy { !($0 is NSNull) })  // 全字段有值，无 null 占位
    }

    @Test func roundTripPreservesFieldByFieldEquality() throws {
        let heartbeat = sampleHeartbeat(placement: .both)
        let decoded = try JSONDecoder().decode(TelemetryHeartbeat.self, from: JSONEncoder().encode(heartbeat))
        #expect(decoded == heartbeat)
    }

    @Test func makeIsPurePassthrough() {
        let id = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_234_567_890)
        let heartbeat = TelemetryHeartbeat.make(
            installationID: id, appVersion: "2.0.1", osVersion: "14.5.1",
            language: "en-US", iconPlacement: .menuBarOnly, sentAt: sentAt
        )
        // 纯函数：输出逐字段等于输入，无任何隐藏环境/时钟读取
        #expect(heartbeat.installationID == id)
        #expect(heartbeat.appVersion == "2.0.1")
        #expect(heartbeat.osVersion == "14.5.1")
        #expect(heartbeat.language == "en-US")
        #expect(heartbeat.iconPlacement == "menuBarOnly")
        #expect(heartbeat.sentAt == sentAt)
    }
}

// MARK: - 发送引擎与调度器（假 URLProtocol，绝不触真网）

@Suite(.serialized) struct TelemetryTransmissionTests {

    private let fixedHeartbeat = TelemetryHeartbeat.make(
        installationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        appVersion: "0.1.0",
        osVersion: "15.0.0",
        language: "zh-Hans",
        iconPlacement: .both,
        sentAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    private func makeSender(resolver: @escaping TelemetrySender.AddressResolver) -> TelemetrySender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryStubProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: TelemetryRedirectHandler(),
            delegateQueue: nil
        )
        return TelemetrySender(session: session, resolveAddresses: resolver)
    }

    // MARK: 闸 1：端点白名单

    @Test func endpointGateAllowsOnlyHTTPSExactPlaceholderHost() throws {
        #expect(TelemetryEndpoint.endpointURL.scheme == "https")
        #expect(TelemetryEndpoint.endpointURL.host(percentEncoded: false) == TelemetryEndpoint.host)
        #expect(TelemetryEndpoint.validateURL(TelemetryEndpoint.endpointURL))
        // 占位域纪律：.invalid 是 RFC2606 保留 TLD，真实解析器永不出公网地址（闸 2 必拒）
        #expect(TelemetryEndpoint.host.hasSuffix(".invalid"))
        // http 降级拒绝
        #expect(!TelemetryEndpoint.validateURL(URL(string: "http://\(TelemetryEndpoint.host)/v1/heartbeat")!))
        // 白名单外域拒绝（含遥测自家白名单外的气象域——两域互不通用）
        #expect(!TelemetryEndpoint.validateURL(URL(string: "https://api.open-meteo.com/v1/forecast")!))
        #expect(!TelemetryEndpoint.validateURL(URL(string: "https://evil.example.com/collect")!))
        // 后缀仿冒拒绝（精确 host 匹配，非 hasSuffix）
        #expect(!TelemetryEndpoint.validateURL(URL(string: "https://\(TelemetryEndpoint.host).evil.example.com/v1/heartbeat")!))
    }

    // MARK: 端到端：发送引擎

    @Test func senderHappyPathDeliversPinnedPayload() async throws {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("{\"ok\":true}".utf8)
        )
        let sender = makeSender(resolver: { _ in ["93.184.216.34"] })
        let delivered = await sender.send(fixedHeartbeat)
        #expect(delivered)
        let captured = TelemetryStubProtocol.store.captured
        #expect(captured.count == 1)
        let request = try #require(captured.first)
        #expect(request.url == TelemetryEndpoint.endpointURL)
        #expect(request.method == "POST")
        #expect(request.contentType == "application/json")
        // 载荷端到端钉死：线上请求体解码回心跳，与入参逐字段相等
        let decoded = try JSONDecoder().decode(TelemetryHeartbeat.self, from: request.body)
        #expect(decoded == fixedHeartbeat)
    }

    @Test func senderBlocksPrivateDNSAnswerBeforeAnyRequest() async {
        TelemetryStubProtocol.store.reset()
        // 仿 DNS 劫持：白名单域解析出内网地址。桩里故意放 200 成功体，
        // 若闸 2 失效测试将拿到 delivered=true 从而失败
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("should-never-load".utf8)
        )
        let sender = makeSender(resolver: { _ in ["192.168.1.1"] })
        #expect(!(await sender.send(fixedHeartbeat)))
        // 关键纪律：请求根本没发出去（闸 2 在 data(for:) 之前）
        #expect(TelemetryStubProtocol.store.count == 0)
    }

    @Test func senderBlocksEmptyDNSAnswerLikePlaceholderDomainReality() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("never".utf8)
        )
        // 占位域 .invalid 在系统解析器下必然得到空表 → fail closed，结构上发不出真网请求
        let sender = makeSender(resolver: { _ in [] })
        #expect(!(await sender.send(fixedHeartbeat)))
        #expect(TelemetryStubProtocol.store.count == 0)
    }

    @Test func senderFailsSilentlyOnHTTPError() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(host: TelemetryEndpoint.host, status: 503, headers: [:], body: Data())
        let sender = makeSender(resolver: { _ in ["93.184.216.34"] })
        // 静默失败契约：不抛错、返回 false——遥测永远不许把错误甩给主流程
        #expect(!(await sender.send(fixedHeartbeat)))
        #expect(TelemetryStubProtocol.store.count == 1)
    }

    // MARK: 闸 3：重定向裁决（直接驱动 delegate 方法）
    // 与 WeatherTests 同论证：本运行时 URLSession 不对自定义 URLProtocol 的 30x 做
    // 重定向处理（不跟随、也不咨询 delegate），故用未 resume 的 dataTask 当
    // originalRequest 载体直接调用 handler（全程零出网）

    private func makeRedirectFixture() -> (session: URLSession, task: URLSessionTask, handler: TelemetryRedirectHandler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryStubProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: TelemetryRedirectHandler(),
            delegateQueue: nil
        )
        let task = session.dataTask(with: TelemetryEndpoint.endpointURL)
        return (session, task, TelemetryRedirectHandler())
    }

    private func redirectResponse(location: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: TelemetryEndpoint.endpointURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": location]
        )!
    }

    @Test func crossHostRedirectIsCancelled() {
        TelemetryStubProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(location: "https://attacker.example/steal"),
            newRequest: URLRequest(url: URL(string: "https://attacker.example/steal")!)
        ) { forwarded = $0 }
        #expect(forwarded == nil)                  // 跨域不放行
        #expect(fixture.task.state == .canceling)  // 且主动取消任务
        #expect(TelemetryStubProtocol.store.count == 0)  // 第二跳从未发出
    }

    @Test func sameHostHTTPSRedirectIsForwarded() {
        TelemetryStubProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        let redirectTo = "https://\(TelemetryEndpoint.host)/v1/heartbeat?retry=1"
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(location: redirectTo),
            newRequest: URLRequest(url: URL(string: redirectTo)!)
        ) { forwarded = $0 }
        #expect(forwarded?.url?.absoluteString == redirectTo)
        #expect(fixture.task.state == .suspended)  // 未取消
        #expect(TelemetryStubProtocol.store.count == 0)
    }

    @Test func sameHostHTTPDowngradeIsCancelled() {
        TelemetryStubProtocol.store.reset()
        let fixture = makeRedirectFixture()
        defer { fixture.session.finishTasksAndInvalidate() }
        let downgraded = "http://\(TelemetryEndpoint.host)/v1/heartbeat"
        var forwarded: URLRequest?
        fixture.handler.urlSession(
            fixture.session,
            task: fixture.task,
            willPerformHTTPRedirection: redirectResponse(location: downgraded),
            newRequest: URLRequest(url: URL(string: downgraded)!)
        ) { forwarded = $0 }
        #expect(forwarded == nil)
        #expect(fixture.task.state == .canceling)
    }

    // MARK: 调度器 tick

    @Test @MainActor func schedulerTickSendsAndRecordsWhenEligibleAndDue() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("{\"ok\":true}".utf8)
        )
        let store = InMemoryTelemetryStore(consent: .optedIn)
        let heartbeat = fixedHeartbeat  // 局部 let 拷贝：@Sendable 闭包不得捕获非 Sendable 的套件实例
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        let scheduler = TelemetryScheduler(
            store: store,
            sender: makeSender(resolver: { _ in ["93.184.216.34"] }),
            makeHeartbeat: { heartbeat },
            isDebugBuild: false,
            networkReachable: { true },
            now: { fixedNow }
        )
        #expect(await scheduler.tick())
        #expect(store.lastSentAt() == fixedNow)  // 送达才落盘，且用 tick 时刻（确定性）
        #expect(TelemetryStubProtocol.store.count == 1)
    }

    @Test @MainActor func schedulerTickSkipsWhenConsentIsNotOptedIn() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("{\"ok\":true}".utf8)
        )
        // 默认关的两态：未询问与明确退出都不发（唯一放行态是 optedIn）
        let heartbeat = fixedHeartbeat  // 局部 let 拷贝：@Sendable 闭包不得捕获非 Sendable 的套件实例
        for consent in [TelemetryConsent.notAsked, .optedOut] {
            let store = InMemoryTelemetryStore(consent: consent)
            let scheduler = TelemetryScheduler(
                store: store,
                sender: makeSender(resolver: { _ in ["93.184.216.34"] }),
                makeHeartbeat: { heartbeat },
                isDebugBuild: false,
                networkReachable: { true },
                now: { Date(timeIntervalSince1970: 1_760_000_000) }
            )
            #expect(!(await scheduler.tick()), "\(consent) 不应发送")
            #expect(store.lastSentAt() == nil)
        }
        #expect(TelemetryStubProtocol.store.count == 0)
    }

    @Test @MainActor func schedulerTickSkipsWithinThrottleWindow() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(
            host: TelemetryEndpoint.host, status: 200, headers: [:], body: Data("{\"ok\":true}".utf8)
        )
        let heartbeat = fixedHeartbeat  // 局部 let 拷贝：@Sendable 闭包不得捕获非 Sendable 的套件实例
        let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryTelemetryStore(consent: .optedIn)
        store.recordSent(at: fixedNow.addingTimeInterval(-23.9 * 3600))  // 距今 23.9h
        let scheduler = TelemetryScheduler(
            store: store,
            sender: makeSender(resolver: { _ in ["93.184.216.34"] }),
            makeHeartbeat: { heartbeat },
            isDebugBuild: false,
            networkReachable: { true },
            now: { fixedNow }
        )
        #expect(!(await scheduler.tick()))
        #expect(store.lastSentAt() == fixedNow.addingTimeInterval(-23.9 * 3600))  // 未被覆写
        #expect(TelemetryStubProtocol.store.count == 0)
    }

    @Test @MainActor func schedulerTickDoesNotRecordWhenDeliveryFails() async {
        TelemetryStubProtocol.store.reset()
        TelemetryStubProtocol.store.push(host: TelemetryEndpoint.host, status: 500, headers: [:], body: Data())
        let heartbeat = fixedHeartbeat  // 局部 let 拷贝：@Sendable 闭包不得捕获非 Sendable 的套件实例
        let store = InMemoryTelemetryStore(consent: .optedIn)
        let scheduler = TelemetryScheduler(
            store: store,
            sender: makeSender(resolver: { _ in ["93.184.216.34"] }),
            makeHeartbeat: { heartbeat },
            isDebugBuild: false,
            networkReachable: { true },
            now: { Date(timeIntervalSince1970: 1_760_000_000) }
        )
        #expect(!(await scheduler.tick()))
        // 失败不落盘：lastSentAt 保持 nil → 下个 tick 自然补发（24h 粒度对迟到不敏感）
        #expect(store.lastSentAt() == nil)
    }
}

// MARK: - 测试替身

/// 调度器持久层的内存实现（协议化注入的测试侧）
final class InMemoryTelemetryStore: TelemetryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var consentState: TelemetryConsent
    private var lastSent: Date?

    init(consent: TelemetryConsent) {
        self.consentState = consent
    }

    func consent() -> TelemetryConsent { lock.withLock { consentState } }
    func lastSentAt() -> Date? { lock.withLock { lastSent } }
    func recordSent(at date: Date) { lock.withLock { lastSent = date } }
}

/// 按 host 维护 FIFO 桩队列并捕获完整请求（URL/方法/头/体）。
/// 手法复用自 WeatherTests 的 MockURLProtocol，但独立成桩：那是另一套件的
/// 进程级单例，跨套件并发无同步会互相踩桩
final class TelemetryStubProtocol: URLProtocol {
    struct CapturedRequest {
        let url: URL
        let method: String?
        let contentType: String?
        let body: Data
    }

    typealias Stub = (status: Int, headers: [String: String], body: Data)

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [Stub]] = [:]
        private var seen: [CapturedRequest] = []

        func reset() { lock.withLock { queues = [:]; seen = [] } }

        func push(host: String, status: Int, headers: [String: String], body: Data) {
            lock.withLock { queues[host, default: []].append((status, headers, body)) }
        }

        func pop(host: String?) -> Stub? {
            lock.withLock {
                guard let host, !queues[host, default: []].isEmpty else { return nil }
                return queues[host]?.removeFirst()
            }
        }

        func record(_ request: CapturedRequest) { lock.withLock { seen.append(request) } }

        var captured: [CapturedRequest] { lock.withLock { seen } }
        var count: Int { lock.withLock { seen.count } }
    }

    static let store = Store()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.store.record(
            CapturedRequest(
                url: request.url ?? URL(fileURLWithPath: "/unknown"),
                method: request.httpMethod,
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: Self.bodyData(of: request)
            )
        )
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

    /// URLSession 会把 httpBody 转写为 httpBodyStream，两者取其一还原请求体
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
