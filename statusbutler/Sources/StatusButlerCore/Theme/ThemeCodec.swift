import Foundation

// T-033 / E7·TH-01~02：.butler-theme 的编解码与校验（文件扩展名由导入导出调用方管理）。

public enum ThemeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// JSON 语法坏 / 结构与 schema 对不上
    case badJSON
    /// schemaVersion 高于当前程序支持的版本（拒绝而非猜语义，向前兼容只保证"新读旧"）
    case schemaTooNew(Int)
    /// 缺 schemaVersion 键：无法判断该按哪个版本解释，宁拒不猜
    case missingVersion

    public var description: String {
        switch self {
        case .badJSON: "主题文件不是有效的 .butler-theme JSON"
        case .schemaTooNew(let v): "主题 schema v\(v) 高于本程序支持的 v\(ButlerTheme.currentSchemaVersion)，请升级应用"
        case .missingVersion: "主题文件缺少 schemaVersion"
        }
    }
}

public enum ThemeCodec {
    /// 先只读版本号的浅探针：schemaVersion 在主结构里是非可选键，
    /// 直接全量解码会把"缺 version"与"其它键坏"都混成同一个解码错误，无法分型报错
    private struct VersionEnvelope: Decodable {
        let schemaVersion: Int?
    }

    /// 编码为可读 JSON；sortedKeys 让同值主题字节稳定，导入前的"差异预览"可直接做文本 diff
    public static func encode(_ theme: ButlerTheme) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 值类型全为 JSON 原生支持的字段，编码不可能失败，强制解包以保住非抛出签名
        return try! encoder.encode(theme)
    }

    public static func decode(_ data: Data) throws -> ButlerTheme {
        guard let envelope = try? JSONDecoder().decode(VersionEnvelope.self, from: data) else {
            throw ThemeError.badJSON
        }
        guard let version = envelope.schemaVersion else {
            throw ThemeError.missingVersion
        }
        guard version <= ButlerTheme.currentSchemaVersion else {
            throw ThemeError.schemaTooNew(version)
        }
        // 未知键忽略：合成 Codable 本就不校验多余键，旧程序读新主题文件不会崩（TH-01 向前兼容）
        guard let theme = try? JSONDecoder().decode(ButlerTheme.self, from: data) else {
            throw ThemeError.badJSON
        }
        return theme
    }

    /// 导入前的 schema 校验入口（TH-03 双击导入的第一道闸）
    public static func validate(_ data: Data) -> Result<ButlerTheme, ThemeError> {
        do {
            return .success(try decode(data))
        } catch let error as ThemeError {
            return .failure(error)
        } catch {
            // decode 目前只抛 ThemeError；兜底防将来引入其它错误类型时静默丢失
            return .failure(.badJSON)
        }
    }

    /// 版本迁移骨架：v1 是唯一现存版本，直通。未来 v2+ 在此按链式步骤升级
    /// （例：v1→v2 改 ringStyle 命名），每步必须纯函数且独立可测，逐步抬到目标版本。
    public static func migrate(_ theme: ButlerTheme, to version: Int) -> ButlerTheme {
        _ = version
        return theme
    }
}
