import Foundation
import Testing
@testable import StatusButlerCore

// T-055：UpdaterFeedInfo 纯函数层——Info.plist 键读取（注入假 dictionary）、占位域 fail-safe、
// 主 Info.plist 的 Sparkle 键契约（占位值钉死，上线换真值时这里的断言提醒同步检查）。
// UpdaterController 本体持有 SPUStandardUpdaterController（AppKit 运行时），不在单测里实例化。

@Suite struct UpdaterControllerTests {

    // MARK: - 键读取（注入假 bundle dict）

    @Test func readsFeedURLAndPublicKeyFromDictionary() {
        let info = UpdaterFeedInfo.from(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": "MEUCIQDtest-public-key",
        ])
        #expect(info.feedURL?.absoluteString == "https://updates.example.com/appcast.xml")
        #expect(info.edPublicKey == "MEUCIQDtest-public-key")
        #expect(info.isConfigured)
    }

    @Test func missingOrEmptyKeysYieldNilAndUnconfigured() {
        // 完全缺失
        let empty = UpdaterFeedInfo.from(infoDictionary: [:])
        #expect(empty.feedURL == nil)
        #expect(empty.edPublicKey == nil)
        #expect(!empty.isConfigured)

        // 空公钥 = 未配置（占位 plist 的 SUPublicEDKey 就是空串）
        let blankKey = UpdaterFeedInfo.from(infoDictionary: [
            "SUFeedURL": "https://updates.example.com/appcast.xml",
            "SUPublicEDKey": "",
        ])
        #expect(blankKey.edPublicKey == nil)
        #expect(!blankKey.isConfigured)

        // 空 feed 串同样落 nil
        let blankURL = UpdaterFeedInfo.from(infoDictionary: ["SUFeedURL": ""])
        #expect(blankURL.feedURL == nil)
        #expect(!blankURL.isConfigured)
    }

    @Test func placeholderInvalidHostIsNeverConfigured() {
        // .invalid 保留域 = 上线前占位：即便将来公钥先填了真值，feed 仍指占位域时一律不放行
        let info = UpdaterFeedInfo.from(infoDictionary: [
            "SUFeedURL": "https://statusbutler.invalid/appcast.xml",
            "SUPublicEDKey": "MEUCIQDtest-public-key",
        ])
        #expect(info.feedURL?.host() == UpdaterFeedInfo.placeholderHost)
        #expect(!info.isConfigured)
    }

    @Test func placeholderHostConstantMatchesMainInfoPlistFeedHost() throws {
        // 占位域常量与主 plist 实际值互证：两边各写一份的字符串必须指同一个域
        let plist = try mainInfoDictionary()
        let feed = try #require(plist["SUFeedURL"] as? String)
        let url = try #require(URL(string: feed))
        #expect(url.host() == UpdaterFeedInfo.placeholderHost)
    }

    // MARK: - 主 Info.plist 的 Sparkle 键契约

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func mainInfoDictionary() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot().appending(path: "Support/Info.plist"))
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            Issue.record("主 Info.plist 反序列化失败")
            return [:]
        }
        return dict
    }

    @Test func mainInfoPlistCarriesMinimalSparkleKeys() throws {
        let plist = try mainInfoDictionary()
        // feed 占位钉死 .invalid（上线换真值时本断言红了即提醒同步改 AboutPane 文案口径）
        #expect((plist["SUFeedURL"] as? String) == "https://statusbutler.invalid/appcast.xml")
        // EdDSA 公钥键在册（占位允许空串——isConfigured=false 已拦下一切更新请求）
        #expect(plist["SUPublicEDKey"] is String)
        // 自动检查开关键在册（Sparkle 2 最小必需三键）
        #expect((plist["SUEnableAutomaticChecks"] as? Bool) == true)
    }
}
