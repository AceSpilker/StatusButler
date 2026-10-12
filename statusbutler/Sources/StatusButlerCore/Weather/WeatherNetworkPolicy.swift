import Darwin
import Foundation

// T-040（A8·WX-03 网络纪律，对齐 A2·S12 红线三）：三道闸的判定核心，全部纯函数 + getaddrinfo 薄封装。
// 闸 1 URL：仅 https + 编译期域名白名单；闸 2 DNS：解析结果全公网才放行；闸 3 重定向：同 host 才放行。

public enum WeatherNetworkPolicy {
    /// WX-03-1 编译期白名单：唯一授权气象数据域（WX-04 默认 Open-Meteo 免 Key）。
    /// 扩充带 Key 服务时在此登记新域，并保持"用户 Key 走 Keychain"的 WX-04 纪律
    public static let allowedHosts: Set<String> = ["api.open-meteo.com"]

    /// URL 构造与白名单共用同一常量，防两处拼写漂移后互相放行
    public static let openMeteoHost = "api.open-meteo.com"

    // MARK: - 闸 1：URL

    public static func validateURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    // MARK: - 闸 2：目标 IP

    /// DNS 解析结果全部为公网地址才放行；空表/无法判定一律拒（fail closed：
    /// 无法证明公网 = 不发请求）
    public static func validateAddresses(_ addresses: [String]) -> Bool {
        guard !addresses.isEmpty else { return false }
        return addresses.allSatisfy(isPublicAddress)
    }

    /// 单地址判定：先按 IPv4 点分、再按 IPv6 冒分解析；两解皆败（如残留
    /// CNAME 字符串）按非公网处理
    public static func isPublicAddress(_ address: String) -> Bool {
        if let octets = ipv4Octets(address) { return isPublicIPv4(octets) }
        if let bytes = ipv6Bytes(address) { return isPublicIPv6(bytes) }
        return false
    }

    /// IPv4 保留/私网段判定（逐段依据）：
    /// - 0/8 "this network"（IANA 特殊注册表）；10/8 RFC1918 A 类私网；127/8 RFC1122 环回
    /// - 100.64/10 RFC6598 CGNAT 共享段；169.254/16 RFC3927 链路本地；172.16/12 RFC1918 B 类私网
    /// - 192.168/16 RFC1918 C 类私网；192.0.2/24、198.51.100/24、203.0.113/24 RFC5737 文档测试段
    /// - 198.18/15 RFC2544 基准测试；240/4 E 类保留（含 255.255.255.255 广播）
    static func isPublicIPv4(_ o: [UInt8]) -> Bool {
        guard o.count == 4 else { return false }
        let (a, b, c, _) = (Int(o[0]), Int(o[1]), Int(o[2]), Int(o[3]))
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192:
            if b == 168 { return false }
            if b == 0 && c == 2 { return false }
            return true
        case 198:
            if (18...19).contains(b) { return false }
            if b == 51 && c == 100 { return false }
            return true
        case 203 where b == 0 && c == 113: return false
        case 240...255: return false
        default: return true
        }
    }

    /// IPv6 非公网形态判定（主要段，逐段依据）：
    /// - ::/128 未指定 与 ::1/128 环回：走 v4 兼容分支折算为 0.0.0.0/0.0.0.1，落入 0/8 被拒
    /// - ::ffff:0:0/96 v4 映射、::/96 v4 兼容（已废弃）→ 校验内嵌 v4
    /// - fe80::/10 RFC4291 链路本地；fc00::/7 RFC4193 ULA；ff00::/8 组播
    /// - 2002::/16 RFC3056 6to4（内嵌 v4 在第 2~5 字节）→ 校验内嵌 v4；2001:db8::/32 RFC3849 文档段
    /// 未覆盖长尾：NAT64 64:ff9b::/96 中段内嵌、ORCHID 等——DNS 常规解析不会返回，
    /// 规格口径（A8·WX-03-2）是"主要私网形态"
    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicIPv4(Array(b[2...5])) }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }
        let headZero = b.prefix(10).allSatisfy { $0 == 0 }
        if headZero && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) {
            return isPublicIPv4(Array(b[12...15]))
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }
        if (b[0] & 0xfe) == 0xfc { return false }
        if b[0] == 0xff { return false }
        return true
    }

    /// inet_pton 严格拒绝缩写、带端口、杂尾形式（比手写 split 可靠）；in_addr/in6_addr
    /// 内存布局即网络序字节，直接取字节免做端序换算
    private static func ipv4Octets(_ literal: String) -> [UInt8]? {
        var addr = in_addr()
        let ok = literal.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
        return ok ? withUnsafeBytes(of: addr) { [UInt8]($0) } : nil
    }

    private static func ipv6Bytes(_ literal: String) -> [UInt8]? {
        var addr = in6_addr()
        let ok = literal.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
        return ok ? withUnsafeBytes(of: addr) { [UInt8]($0) } : nil
    }

    // MARK: - DNS 预解析（getaddrinfo 薄封装）

    /// 阻塞系统调用——严禁主线程/协作线程直接调用；异步入口 resolveHostOffMain(_:)
    public static func resolveHost(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM  // 只取可连 TCP 的地址，顺带滤掉裸 CNAME 行
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            let info = node.pointee
            if info.ai_family == AF_INET, let sa = info.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                        addresses.append(stringFromCBuffer(text))
                    }
                }
            } else if info.ai_family == AF_INET6, let sa = info.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var addr = sin6.pointee.sin6_addr
                    var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &addr, &text, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        addresses.append(stringFromCBuffer(text))
                    }
                }
            }
            cursor = info.ai_next
        }
        return addresses
    }

    /// inet_ntop 写入的 NUL 结尾 CChar 缓冲 → Swift String（init(cString:) 对数组形态已废弃）
    private static func stringFromCBuffer(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static let resolverQueue = DispatchQueue(label: "statusbutler.weather.dns", qos: .utility)

    /// 把阻塞的 getaddrinfo 挪到专属串行队列执行，不占 Swift 协作线程池
    public static func resolveHostOffMain(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            resolverQueue.async { continuation.resume(returning: resolveHost(host)) }
        }
    }

    // MARK: - 闸 3：重定向

    /// 同 host（且重定向目标仍过 URL 白名单）才放行；跨域/降级 http 一律 cancel。
    /// 防 30x 把请求引向白名单外目标——DNS 劫持/中间人改写的常见跳板。
    /// @unchecked Sendable 论证：无可变实例状态，判定只读 task/request 局部值
    public final class SafeRedirectHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
                WeatherNetworkPolicy.validateURL(newURL)
            else {
                task.cancel()
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
