import Foundation

// T-221 更新扫描（E25·UPDT-01）：brew cask 数据源比对提示，纯提示不代装。
// 网络三道闸同 WX-03 纪律（https+域名白名单 / DNS 全公网 / 同域重定向）——
// IP/DNS 判定复用 WeatherNetworkPolicy 的纯函数（IP 语义与域名无关，各域白名单独立；
// 引用而非复制，避免两份 RFC 段表漂移）。

// MARK: - brew list 解析（纯函数）

/// 本地已装 cask（brew list --cask 一行）
public struct InstalledCask: Equatable, Sendable, Identifiable {
    public let name: String
    /// `--versions` 输出携带的版本；裸名单无版本 → nil（不虚构）
    public let version: String?

    public init(name: String, version: String?) {
        self.name = name
        self.version = version
    }

    public var id: String { name }
}

public enum BrewListParser {
    /// `brew list --cask --versions` 输出解析：每行 "<token> [<version>]..."
    /// （cask 重装残留会出现同 token 双版本，取首个为有效版本）。
    /// 兼容不带 --versions 的裸名单（token 单字段，版本 nil）。
    /// 空行/前导空白行跳过；头部无表头（brew 不打表头，不防御性跳首行）
    public static func parse(_ output: String) -> [InstalledCask] {
        var results: [InstalledCask] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard let token = fields.first else { continue }
            let version = fields.count > 1 ? String(fields[1]) : nil
            results.append(InstalledCask(name: String(token), version: version))
        }
        return results
    }
}

// MARK: - 网络三道闸（同 WX-03 范式）

public enum UpdateNetworkPolicy {
    /// 唯一授权数据源：Homebrew 官方 cask API（formulae.brew.sh，与 brew CLI 同源）。
    /// 编译期白名单，扩充数据源时在此登记
    public static let allowedHosts: Set<String> = ["formulae.brew.sh"]
    public static let caskAPIHost = "formulae.brew.sh"

    /// token 合法字符（brew cask token 规范：小写字母数字与连字符）。
    /// URL 构造前先过它——防 token 里塞 "/" 或 "?" 做 path/query 注入
    static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { ($0.isASCII && $0.isLetter && $0.isLowercase) || $0 == "-" || $0.isNumber }
    }

    /// 单 cask 元数据 URL：https://formulae.brew.sh/api/cask/<token>.json
    /// （token 不合法 → nil，构造与校验不分离）
    public static func caskInfoURL(token: String) -> URL? {
        guard isSafeToken(token) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = caskAPIHost
        components.path = "/api/cask/\(token).json"
        return components.url
    }

    /// 闸 1：https + 域名白名单（口径同 WeatherNetworkPolicy.validateURL，白名单独立）
    public static func validateURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    // 闸 2（DNS 解析结果全公网）与 DNS 预解析直接复用 WeatherNetworkPolicy：
    // validateAddresses / resolveHostOffMain 均为与域名无关的纯函数/工具

    /// 闸 3：同 host（且目标仍过本域白名单）才放行；跨域/降级 http 一律 cancel。
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
                UpdateNetworkPolicy.validateURL(newURL)
            else {
                task.cancel()
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

// MARK: - 比对结果（纯函数）

/// 单 cask 比对结论
public struct CaskUpdate: Equatable, Sendable, Identifiable {
    public let name: String
    public let installedVersion: String?
    public let latestVersion: String?
    /// nil = 无法判定（本地或远端版本缺测——不猜"最新"）
    public let isOutdated: Bool?

    public init(name: String, installedVersion: String?, latestVersion: String?, isOutdated: Bool?) {
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isOutdated = isOutdated
    }

    public var id: String { name }

    /// 官网深链（"去更新"出口——cask 官方页；纯提示不代装）
    public var homepageURL: URL? { CaskComparison.caskPageURL(name: name) }
}

public enum CaskComparison {
    /// 版本比对：远端有且 ≠ 本地 → 可更新；任一缺 → nil（无法判定）。
    /// 字符串不等即判可更新——cask 版本号体系五花八门（含 auto_updates 标记的
    /// cask 本地版本常年滞后），语义化版本排序会误判，保守口径是唯一诚实的
    public static func compare(installed: InstalledCask, latestVersion: String?) -> CaskUpdate {
        let isOutdated: Bool?
        if let latest = latestVersion, let local = installed.version {
            isOutdated = latest != local
        } else {
            isOutdated = nil
        }
        return CaskUpdate(
            name: installed.name,
            installedVersion: installed.version,
            latestVersion: latestVersion,
            isOutdated: isOutdated
        )
    }

    /// cask 官方页深链（token 复用 UpdateNetworkPolicy.isSafeToken 闸——
    /// 深链目标也是 URL，注入面同源校验）
    public static func caskPageURL(name: String) -> URL? {
        guard UpdateNetworkPolicy.isSafeToken(name) else { return nil }
        return URL(string: "https://\(UpdateNetworkPolicy.caskAPIHost)/cask/\(name)")
    }

    /// 告警/汇总文案：可更新 N 个（>0 是警报口径）/ 全部最新 / 无可判定项 / 空清单
    public static func summaryText(for results: [CaskUpdate]) -> String {
        let outdated = results.filter { $0.isOutdated == true }
        if results.isEmpty { return "未发现已安装的 cask" }
        if !outdated.isEmpty { return "发现 \(outdated.count) 个可更新" }
        if results.contains(where: { $0.isOutdated == nil }) { return "无确证的可更新项（部分版本无法比对）" }
        return "已安装的 cask 均为最新"
    }
}

// MARK: - Homebrew API 比对（占位实现）

/// 版本源协议（注入；测试喂假实现）
public protocol CaskVersionFetching: Sendable {
    /// token → 最新版本；失败/无此 cask → nil（调用方判"无法比对"，不猜）
    func latestVersion(token: String) async -> String?
}

/// cask JSON 的 version 字段提取（纯函数，测试喂固定 JSON）
public enum CaskInfoParser {
    public static func parseVersion(fromJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String
        else { return nil }
        return version.isEmpty ? nil : version
    }
}

/// Homebrew cask API 取版本（占位——上线前由主线决定缓存/重试策略）。
/// 三道闸全数落实：闸 1 在 caskInfoURL 构造内；闸 2 DNS 预解析全公网；
/// 闸 3 SafeRedirectHandler 同域放行。任一闸不过 → nil（fail closed，不发请求）。
public struct HomebrewCaskFetcher: CaskVersionFetching {
    public init() {}

    public func latestVersion(token: String) async -> String? {
        guard let url = UpdateNetworkPolicy.caskInfoURL(token: token) else { return nil }
        guard UpdateNetworkPolicy.validateURL(url) else { return nil }
        let addresses = await WeatherNetworkPolicy.resolveHostOffMain(UpdateNetworkPolicy.caskAPIHost)
        guard WeatherNetworkPolicy.validateAddresses(addresses) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // 闸 1~3 都在 URL/会话侧；此处只发 GET
        let session = URLSession(
            configuration: .ephemeral,
            delegate: UpdateNetworkPolicy.SafeRedirectHandler(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else { return nil }
        return CaskInfoParser.parseVersion(fromJSON: data)
    }
}

// MARK: - 本地清单真实现（供主线组合 provider 用）

/// `brew list --cask --versions` 子进程读取（阻塞，折进 detached——同
/// PluginRunner 的纪律）。brew 无固定安装位（Apple Silicon /opt/homebrew、
/// Intel /usr/local），按候选位探测，全缺 → nil（机器没装 brew 是正常态，
/// 面板占位"未接入"，不是错误）
public enum BrewListRunner {
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func readOutput() async -> String? {
        await Task.detached(priority: .utility) { Self.readOnce() }.value
    }

    static func readOnce() -> String? {
        let brewPath = brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brewPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["list", "--cask", "--versions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // 丢弃 stderr（brew 诊断噪声不进宿主控制台）
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
