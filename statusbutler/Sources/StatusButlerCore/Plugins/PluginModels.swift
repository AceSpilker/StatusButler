import Foundation

// E16·SP-01/SP-02（A12）：脚本插件槽模型层。
// 红线（AGENTS.md）：插件引擎绝不能变成任意执行面——解释器白名单是第一道闸，
// 沙盒 profile 与 JSON 行协议解析均为纯函数，便于钉死测试。

/// 插件清单：插件目录内 manifest.json 的解码目标。
/// 解释器必须命中白名单、刷新建议 ≥10s，否则 `isValid == false` 由扫描/执行两端拒载。
public struct PluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 只允许系统自带四件套；/usr/bin/osascript、perl 等一律拒绝（防借道提权）
    public var interpreter: String
    /// 刷新建议下限 10s：插件轮询不能击穿能效铁律（采样"有人看才运行"）
    public var refreshHintSeconds: Int
    public var author: String?

    public init(
        id: String,
        name: String,
        interpreter: String,
        refreshHintSeconds: Int,
        author: String? = nil
    ) {
        self.id = id
        self.name = name
        self.interpreter = interpreter
        self.refreshHintSeconds = refreshHintSeconds
        self.author = author
    }

    /// 白名单解释器集合：仅系统自带、无脚本任意代码引擎外溢的路径。
    /// 注意 /usr/bin/swift 在严格沙盒（禁写）下因编译器需写模块缓存而实际不可用，
    /// 保留在白名单是为了与 SP-01 规格对齐，后续放宽写路径时可自动生效。
    public static let allowedInterpreters: Set<String> = [
        "/bin/sh", "/bin/bash", "/usr/bin/python3", "/usr/bin/swift",
    ]

    public var isInterpreterAllowed: Bool { Self.allowedInterpreters.contains(interpreter) }

    /// id 会拼进槽位 key（"plugin:"+id）与日志，禁路径分隔符与命名空间分隔符；
    /// name 为空则管理页无法展示。两条都属加载闸门。
    public var isValid: Bool {
        !id.isEmpty
            && !id.contains("/") && !id.contains(":")
            && !name.isEmpty
            && isInterpreterAllowed
            && refreshHintSeconds >= 10
    }
}

/// 插件一次执行的结局。failed 携带诊断摘要（退出码/stderr 片段）。
public enum PluginOutput: Equatable, Sendable {
    case success(SlotScene)
    case failed(String)
    case timeout
    case disabled
}

// MARK: - 沙盒 profile 生成（SP-02 生命线）

/// 纯函数生成 sandbox-exec 的 SBPL profile：
/// 默认放行读/执行（脚本要读系统状态），拒绝一切网络、拒绝一切文件写，
/// 唯一例外是 allowWrite 指定的输出文件。
public enum PluginSandbox {
    /// - Important: 调用方必须传符号链接已解析的绝对路径——SBPL 的 subpath
    ///   按内核真实路径匹配（/tmp 实为 /private/tmp、/var 实为 /private/var），
    ///   传未解析路径会导致唯一写路径落空、插件全部 failed。
    public static func sandboxProfile(allowWrite path: String) -> String {
        // SBPL 字符串字面量转义（防御路径中出现引号/反斜杠破坏 profile 结构）
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath "\(escaped)"))
"""
    }
}

// MARK: - JSON 行协议（SP-01）

/// 输出协议：脚本向输出文件写一行 JSON：
/// `{"symbol":..,"value":..,"level":..,"warning":bool}`
/// 容错原则：value 接受字符串或数字、未知键忽略、缺字段置 nil；
/// 坏 JSON / 空输出一律 nil（调用方判 failed），绝不静默编造数据。
public enum PluginProtocol {
    /// 解析整份输出文件：取首个非空行作为协议行，其余行（诊断噪声）忽略；
    /// 首行即坏行则整体失败——协议行必须在第一行，防止脚本把错误日志排在前面。
    public static func parseScene(output: String) -> SlotScene? {
        guard let first = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
        else { return nil }
        return parseScene(line: String(first))
    }

    /// 解析单行；CR/空白容忍（脚本可能带 CRLF）。
    public static func parseScene(line: String) -> SlotScene? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(LineDTO.self, from: data)
        else { return nil }
        // level 契约 0...4：越界夹紧而不是拒收（槽位体系以 4 点为满格）
        let level = dto.level.map { min(max($0, 0), 4) }
        return SlotScene(
            symbol: dto.symbol,
            valueText: dto.value,
            level: level,
            isWarning: dto.warning ?? false
        )
    }

    private struct LineDTO: Decodable {
        let symbol: String?
        let value: String?
        let level: Int?
        let warning: Bool?

        enum CodingKeys: String, CodingKey { case symbol, value, level, warning }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try? c.decode(String.self, forKey: .symbol)
            level = try? c.decode(Int.self, forKey: .level)
            warning = try? c.decode(Bool.self, forKey: .warning)
            // value 主值脚本侧最常直接 echo 数字：字符串/整数/浮点都收
            if let s = try? c.decode(String.self, forKey: .value) {
                value = s
            } else if let i = try? c.decode(Int.self, forKey: .value) {
                value = String(i)
            } else if let d = try? c.decode(Double.self, forKey: .value) {
                value = String(d)
            } else {
                value = nil
            }
        }
    }
}
