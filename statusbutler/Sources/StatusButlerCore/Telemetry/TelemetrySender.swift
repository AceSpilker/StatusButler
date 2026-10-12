import Foundation

// T-055a：心跳发送引擎 + 调度器骨架。网络纪律复用 WeatherNetworkPolicy 的三道闸
// （该文件禁改，故闸 2/闸 3 直接 import 复用其类型与 IP 校验，闸 1 用本模块独立白名单）：
// 闸 1 https + 遥测域白名单（编译期常量）；闸 2 DNS 解析后全公网 IP 才放行；
// 闸 3 同 host 重定向才放行。发送失败一律静默——遥测永远不许影响主流程。

// MARK: - 端点（编译期常量）

/// 遥测端点：占位域 + 白名单判定，全部编译期常量防运行时篡改。
/// `.invalid` 是 RFC 2606 保留 TLD——系统解析器永不出公网地址，闸 2 必然拒绝，
/// 即占位期内这套引擎结构完备但物理发不出任何真网请求（fail-safe by design）
public enum TelemetryEndpoint {
    /// 占位域：上线前替换为真实遥测域（同时保持"仅 https + 域名白名单"纪律，见 S12 红线三）
    public static let host = "telemetry.statusbutler.invalid"
    static let path = "/v1/heartbeat"

    /// URL 构造与白名单共用同一常量，防两处拼写漂移后互相放行（与天气闸同构）
    public static let endpointURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        // scheme/host/path 全为编译期字面量，force unwrap 不会触发（与 WeatherNetworkPolicy
        // 的白名单常量同级别的"常量即契约"论证）
        return components.url!
    }()

    /// 闸 1：仅 https + 精确 host 匹配（非 hasSuffix，仿冒后缀域不放行）
    public static func validateURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let urlHost = url.host(percentEncoded: false)?.lowercased() else { return false }
        return urlHost == host
    }
}

// MARK: - 闸 3：重定向裁决

/// 同 host（且重定向目标仍过遥测闸 1）才放行；跨域/降级 http 一律 cancel。
/// 独立于 WeatherNetworkPolicy.SafeRedirectHandler（其闸 1 钉死气象白名单，且该文件禁改），
/// 判定逻辑同构：30x 是 DNS 劫持/中间人把请求引向白名单外的常见跳板
/// @unchecked Sendable 论证：无可变实例状态，裁决只读 task/request 局部值
public final class TelemetryRedirectHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard
            let newURL = request.url,
            let originalHost = task.originalRequest?.url?.host(percentEncoded: false)?.lowercased(),
            let newHost = newURL.host(percentEncoded: false)?.lowercased(),
            originalHost == newHost,
            TelemetryEndpoint.validateURL(newURL)
        else {
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - 发送引擎

public struct TelemetrySender: Sendable {
    /// DNS 解析注入点：默认走系统解析（阻塞调用已由 WeatherNetworkPolicy 挪出协作线程池）；
    /// 测试注入静态表驱动闸 2，不碰真网
    public typealias AddressResolver = @Sendable (_ host: String) async -> [String]

    private let session: URLSession
    private let resolveAddresses: AddressResolver

    /// session 注入用于测试（假 URLProtocol）；默认 ephemeral 会话绑遥测重定向闸——
    /// 不留磁盘缓存（心跳是一次性 POST，无任何复读价值），10s 超时上限
    public init(session: URLSession? = nil, resolveAddresses: AddressResolver? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.waitsForConnectivity = false
            self.session = URLSession(
                configuration: configuration,
                delegate: TelemetryRedirectHandler(),
                delegateQueue: nil
            )
        }
        self.resolveAddresses = resolveAddresses ?? { host in
            await WeatherNetworkPolicy.resolveHostOffMain(host)
        }
    }

    /// 发送一次心跳。返回是否送达（2xx）；任何失败一律静默返回 false，绝不抛错——
    /// 调用方（调度器/主流程）不需要也不应该区分失败原因（OG-FR-201 心跳非关键路径）
    public func send(_ heartbeat: TelemetryHeartbeat) async -> Bool {
        // 闸 1：URL 常量自检（纵深防御：常量被误改时在此短路，不碰网络）
        let url = TelemetryEndpoint.endpointURL
        guard TelemetryEndpoint.validateURL(url) else { return false }
        // 闸 2：DNS 预解析 → 全公网才放行；与 URLSession 内部二次解析的 TOCTOU 窗口
        // 由闸 3 的同 host + https 约束兜底（与 WeatherProvider 同一论证口径）
        let addresses = await resolveAddresses(TelemetryEndpoint.host)
        guard WeatherNetworkPolicy.validateAddresses(addresses) else { return false }
        // 闸 3 在 session delegate 上：跨 host 重定向被 cancel，上浮为 cancelled

        // 编码失败 = 心跳载荷结构被破坏（键集被钉死，理论不可达）→ 静默不发
        guard let body = try? JSONEncoder().encode(heartbeat) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            // 静默：网络错误/取消/超时都不上浮（重试节奏由调度器 24h 节流天然决定，
            // 本层刻意不做退避重试，杜绝遥测重试风暴）
            return false
        }
    }
}

// MARK: - 调度器持久层（协议化注入）

/// 调度器对持久层的最小依赖。协议化是为了测试注入内存实现，
/// 也是为将来把 consent 接入设置中心留的缝（设置中心改 consent，本协议不动）
public protocol TelemetryPersisting: Sendable {
    func consent() -> TelemetryConsent
    func lastSentAt() -> Date?
    /// 仅在成功送达后记录（失败不记录 → 下个 tick 补发，24h 粒度对迟到不敏感）
    func recordSent(at date: Date)
}

/// 生产持久层：三键全走 UserDefaults，键常量登记在 TelemetryPolicy。
/// @unchecked Sendable 论证：UserDefaults 自身线程安全，本类无可变实例状态
public final class TelemetryDefaultsStore: TelemetryPersisting, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func consent() -> TelemetryConsent {
        guard let raw = defaults.string(forKey: TelemetryPolicy.consentKey) else { return .notAsked }
        return TelemetryConsent(rawValue: raw) ?? .notAsked
    }

    public func lastSentAt() -> Date? {
        defaults.object(forKey: TelemetryPolicy.lastSentAtKey) as? Date
    }

    public func recordSent(at date: Date) {
        defaults.set(date, forKey: TelemetryPolicy.lastSentAtKey)
    }
}

// MARK: - 调度器骨架

/// 心跳调度骨架：start 拉起低频循环（tick 间隔远小于 24h 节流，容忍进程重启错过的整点），
/// 每次 tick 先过资格三轴 + 24h 节流，全过才发、送达才落盘。
/// 能效纪律：循环内只有 sleep + 廉价判定，无网络活动——网络只在资格全绿时发生一次
@MainActor
public final class TelemetryScheduler {
    /// tick 间隔：1h。比 24h 节流细 24 倍，足够覆盖"启动即查 + 常驻补发"两类时机
    public static let tickInterval: TimeInterval = 60 * 60

    private let store: any TelemetryPersisting
    private let sender: TelemetrySender
    private let makeHeartbeat: @Sendable () -> TelemetryHeartbeat
    private let isDebugBuild: Bool
    private let networkReachable: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var loopTask: Task<Void, Never>?

    public init(
        store: any TelemetryPersisting,
        sender: TelemetrySender,
        makeHeartbeat: @escaping @Sendable () -> TelemetryHeartbeat,
        isDebugBuild: Bool,
        networkReachable: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.sender = sender
        self.makeHeartbeat = makeHeartbeat
        self.isDebugBuild = isDebugBuild
        self.networkReachable = networkReachable
        self.now = now
    }

    /// 拉起常驻循环；重复调用幂等（单实例单循环）。Task 继承 @MainActor 上下文，
    /// sleep 挂起不占线程；tick 内 await 网络调用跳出主线程执行。
    /// weak self：宿主释放后循环随之退出，不产生空转任务
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                // nil = 调度器已释放，退出防任务空转；sleep 期间不持强引用
                guard await self?.tick() != nil else { return }
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 单次判定 + 发送。公开给测试直接驱动（start 的循环只是周期性调它）
    @discardableResult
    public func tick() async -> Bool {
        let sentAt = now()
        // 资格三轴：同意态（默认关）/ 构建资格分离 / 网络可达
        guard TelemetryPolicy.shouldSend(
            consent: store.consent(),
            isDebugBuild: isDebugBuild,
            networkReachable: networkReachable()
        ) else { return false }
        // 24h 节流：未到期不发（含上次发送失败后的自然重试窗口）
        guard TelemetryPolicy.isDue(lastSentAt: store.lastSentAt(), now: sentAt) else { return false }
        let delivered = await sender.send(makeHeartbeat())
        if delivered { store.recordSent(at: sentAt) }
        return delivered
    }
}
