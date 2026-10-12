import Foundation
import os

// T-040（A8·WX-03/04）：WeatherProvider 协议 + Open-Meteo 实现 + 30 分钟缓存与失败静默。
// 取数 = 三道闸串联：URL 白名单 → DNS/IP 公网校验 → 同 host 重定向（session delegate）。
// 重试策略刻意缺失：单次超时 10s，退避节奏由调用方（未来 WeatherSlot 控制器）决定，杜绝重试风暴。

// Error 协议是 Result<Success, Failure> 的硬约束；Equatable 驱动测试断言
public enum WeatherError: Error, Equatable, Sendable {
    case badURL
    case blockedAddress
    case network(String)
    case decode
    /// WX-04 预留：带 Key 服务接入后映射 HTTP 429；当前 Open-Meteo 免 Key 不会产生
    case rateLimitedPlaceholder
}

public protocol WeatherProviding: Sendable {
    func fetch(latitude: Double, longitude: Double) async -> Result<WeatherNow, WeatherError>
}

public struct OpenMeteoProvider: WeatherProviding {
    /// DNS 解析注入点：默认走系统解析；测试注入静态表驱动闸 2，不碰真网
    public typealias AddressResolver = @Sendable (_ host: String) async -> [String]

    private let session: URLSession
    private let resolveAddresses: AddressResolver

    /// session 注入用于测试（假 URLProtocol）；默认会话绑重定向闸 delegate——
    /// 每个 session 强持有 delegate，provider 应按 app 生命周期创建一次
    public init(session: URLSession? = nil, resolveAddresses: AddressResolver? = nil) {
        if let session {
            self.session = session
        } else {
            // ephemeral：不留磁盘缓存（缓存唯一入口是 WeatherCache）；
            // 10s 超时 = WX-03-3 单次请求上限，重试/退避不在本层
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.waitsForConnectivity = false
            self.session = URLSession(
                configuration: configuration,
                delegate: WeatherNetworkPolicy.SafeRedirectHandler(),
                delegateQueue: nil
            )
        }
        // 默认 resolver 必须跳出协作线程池（getaddrinfo 阻塞）
        self.resolveAddresses = resolveAddresses ?? { host in
            await WeatherNetworkPolicy.resolveHostOffMain(host)
        }
    }

    public func fetch(latitude: Double, longitude: Double) async -> Result<WeatherNow, WeatherError> {
        // 闸 1：https + 域名白名单（参数拼接错误在此短路，不碰网络）
        guard let url = Self.forecastURL(latitude: latitude, longitude: longitude),
              WeatherNetworkPolicy.validateURL(url) else {
            return .failure(.badURL)
        }
        // 闸 2：DNS 预解析 → 全公网才放行。与 URLSession 内部二次解析间存在微小
        // TOCTOU 窗口（DNS rebinding）；闸 3 的同 host + https 约束把可利用面压到
        // "白名单域自身被 rebind"，完整封堵需 IP 钉扎，超出本任务范围
        let host = url.host(percentEncoded: false) ?? ""
        let addresses = await resolveAddresses(host)
        guard WeatherNetworkPolicy.validateAddresses(addresses) else {
            return .failure(.blockedAddress)
        }
        // 闸 3 在 session delegate 上：跨 host 重定向被 cancel，上浮为 cancelled 网络错误

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network("非 HTTP 响应"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.network("HTTP \(http.statusCode)"))
            }
            guard let now = Self.parse(data: data, fetchedAt: Date()) else {
                return .failure(.decode)
            }
            return .success(now)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 参数拼写与 Open-Meteo 文档核对（2026-10）：
    /// current=temperature_2m,weather_code；daily=temperature_2m_max,temperature_2m_min；
    /// daily 必须带 timezone → auto（文档明示 daily 场景 timezone 必填）
    static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = WeatherNetworkPolicy.openMeteoHost
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components.url
    }

    /// 只解码白名单字段（current 双值 + daily 首日高低温），其余键一概忽略：
    /// 服务端加字段不破兼容，解码面也不随响应膨胀
    static func parse(data: Data, fetchedAt: Date) -> WeatherNow? {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double]?
                let temperature_2m_min: [Double]?
            }
            let current: Current
            let daily: Daily?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return WeatherNow(
            temperatureC: decoded.current.temperature_2m,
            weatherCode: decoded.current.weather_code,
            dailyMaxC: decoded.daily?.temperature_2m_max?.first,
            dailyMinC: decoded.daily?.temperature_2m_min?.first,
            fetchedAt: fetchedAt
        )
    }
}

// MARK: - 缓存与失败静默（WX-03-3）

/// 内存单帧缓存：30 分钟新鲜期内直接复用；过期值保留作"上次成功时间"的展示依据。
/// 线程安全：唯一可变状态在 OSAllocatedUnfairLock 内，其余全为 let
public final class WeatherCache: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: WeatherNow?.none)

    public init() {}

    /// WX-03-3 缓存 TTL；纯决策函数化便于边界测试
    public static let ttl: TimeInterval = 30 * 60

    /// 新鲜 = fetchedAt 距 now 严格小于 ttl（满 1800s 整点即过期）
    public static func isFresh(fetchedAt: Date, now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) < ttl
    }

    /// 仅新鲜期内返回；过期返回 nil（过期值改走 lastKnown 展示）
    public func fresh(now: Date = Date()) -> WeatherNow? {
        state.withLock { entry in
            guard let entry, Self.isFresh(fetchedAt: entry.fetchedAt, now: now, ttl: Self.ttl) else { return nil }
            return entry
        }
    }

    /// 过期也保留的最近一次成功值——失败静默时"上次成功时间"的数据来源
    public func lastKnown() -> WeatherNow? {
        state.withLock { $0 }
    }

    public func store(_ weather: WeatherNow) {
        state.withLock { $0 = weather }
    }

    /// 失败静默文案（WX-03-3）：无任何成功记录 → "暂无数据"；有 → 附上次成功时间。
    /// 只报状态不报错误细节——网络错误不该甩进状态栏。
    /// DateFormatter 每次新建：实例非 Sendable，做静态缓存会破严格并发；
    /// 本方法只在失败展示路径调用，频次可忽略
    public func quietFailureText(now: Date = Date()) -> String {
        guard let last = lastKnown() else { return "暂无数据" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")  // 固定 24 小时制，不随系统 12h 设置摆动
        return "暂无数据 · 更新于 " + formatter.string(from: last.fetchedAt)
    }
}
