import Testing
import Foundation
@testable import StatusButlerCore

// T-033: 主题模型/编解码/校验/预设（E7·TH-01~05 的纯逻辑层）
@Suite struct ThemeTests {
    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: 编解码

    @Test func roundTripEncodeDecodePreservesTheme() throws {
        let original = ThemePresets.all["colorful"]!
        let restored = try ThemeCodec.decode(ThemeCodec.encode(original))
        #expect(restored == original)
    }

    @Test func encodedOutputIsReadableJSONObject() throws {
        let data = ThemeCodec.encode(ThemePresets.all["classicMac"]!)
        // prettyPrinted 产出多行文本，sortedKeys 保证同值主题字节稳定（差异预览可做文本 diff）
        #expect(String(decoding: data, as: UTF8.self).contains("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test func unknownKeysAreIgnoredForForwardCompatibility() throws {
        // 未来版本主题文件带新键时，旧程序导入应成功而非报错
        let data = json([
            "schemaVersion": 1,
            "appearance": ["iconSize": 20, "futureNanoEffect": true],
            "sections": ["appearance"],
            "footerSlotID": "clock",
            "someFutureTopLevelKey": ["a", "b"],
        ])
        let theme = try ThemeCodec.decode(data)
        #expect(theme.appearance?.iconSize == 20)
        #expect(theme.sections == ["appearance"])
    }

    // MARK: 校验失败分型

    @Test func validateAcceptsPresetFile() {
        let result = ThemeCodec.validate(ThemeCodec.encode(ThemePresets.all["darkNight"]!))
        #expect(Result.success(ThemePresets.all["darkNight"]!) == result)
    }

    @Test func schemaTooNewIsRejected() {
        let result = ThemeCodec.validate(json(["schemaVersion": 99]))
        #expect(.failure(.schemaTooNew(99)) == result)
    }

    @Test func missingVersionIsRejected() {
        let result = ThemeCodec.validate(json(["appearance": ["iconSize": 18]]))
        #expect(.failure(.missingVersion) == result)
    }

    @Test func malformedJSONIsRejected() {
        #expect(.failure(.badJSON) == ThemeCodec.validate(Data("not json".utf8)))
        // 合法 JSON 但结构对不上 schema（键类型错）同样按 badJSON 分型
        #expect(.failure(.badJSON) == ThemeCodec.validate(json(["schemaVersion": "one"])))
    }

    @Test func legacyVersionEqualOrOlderDecodes() throws {
        // "旧读旧"必须可用：v1 程序读 v1 主题
        let theme = try ThemeCodec.decode(json(["schemaVersion": 1]))
        #expect(theme.schemaVersion == 1)
    }

    // MARK: hex 解析

    @Test func hexValidSixDigitsParsesToRGB() {
        let color = ButlerTheme.color(fromHex: "1F3A5F")
        #expect(color?.r ?? 0 == Double(0x1F) / 255)
        #expect(color?.g ?? 0 == Double(0x3A) / 255)
        #expect(color?.b ?? 0 == Double(0x5F) / 255)
        #expect(color?.a ?? 0 == 1)
    }

    @Test func hexHashPrefixAndAlphaEightDigitsParse() {
        // 调用方直接粘贴 CSS 形式 "#RRGGBBAA" 不应失败；字节序按 CSS 的 RGBA
        let color = ButlerTheme.color(fromHex: "#1F3A5F80")
        #expect(color?.r ?? 0 == Double(0x1F) / 255)
        #expect(color?.a ?? 0 == Double(0x80) / 255)
        // 大小写与空白均容忍
        #expect(ButlerTheme.color(fromHex: " #ff00ff ") != nil)
    }

    @Test func hexInvalidInputsReturnNil() {
        for bad in ["", "12345", "1234567", "GGGGGG", "1F3A5G", "#", "  "] {
            #expect(ButlerTheme.color(fromHex: bad) == nil, "应拒绝: \(bad)")
        }
    }

    // MARK: 预设

    @Test func sixPresetsExistAndArePairwiseDistinct() {
        #expect(ThemePresets.all.count == 6)
        let themes = Array(ThemePresets.all.values)
        for i in themes.indices {
            for j in themes.indices where j > i {
                #expect(themes[i] != themes[j], "\(themes[i]) 与 \(themes[j]) 趋同")
            }
        }
    }

    @Test func presetKeyFieldsMatchTheirPositioning() {
        let keys = ["minimal", "highContrast", "colorful", "darkNight", "classicMac", "largeText"]
        #expect(Set(ThemePresets.all.keys) == Set(keys))

        let minimal = ThemePresets.all["minimal"]!
        #expect(minimal.appearance?.iconSize == 16)
        #expect(minimal.appearance?.showsBatteryPercentage == false)
        #expect(minimal.appearance?.ringStyle == .plain)

        let highContrast = ThemePresets.all["highContrast"]!
        #expect(highContrast.appearance?.batteryThreshold == 30)
        #expect(highContrast.appearance?.accentHex != nil)

        let colorful = ThemePresets.all["colorful"]!
        #expect(colorful.appearance?.chargingHex != nil)
        #expect(colorful.appearance?.ringStyle == .segmented)

        let darkNight = ThemePresets.all["darkNight"]!
        #expect(darkNight.appearance?.accentHex == "64D2FF")

        let classicMac = ThemePresets.all["classicMac"]!
        #expect(classicMac.appearance?.ringStyle == .bezel)
        #expect(classicMac.footerSlotID == "volume")

        let largeText = ThemePresets.all["largeText"]!
        #expect(largeText.appearance?.iconSize == 24)
        #expect((largeText.appearance?.symbolScale ?? 0) > 1)
    }

    @Test func presetHexColorsAllParse() {
        // 预设里写死的强调色必须是合法 hex，否则渲染层回退色会静默掩盖预设失配
        for (key, theme) in ThemePresets.all {
            for hex in [theme.appearance?.accentHex, theme.appearance?.warningHex, theme.appearance?.chargingHex].compactMap({ $0 }) {
                #expect(ButlerTheme.color(fromHex: hex) != nil, "\(key) 的 \(hex) 非法")
            }
        }
    }

    // MARK: 迁移骨架

    @Test func migrateSkeletonIsPassThrough() {
        let theme = ThemePresets.all["minimal"]!
        #expect(ThemeCodec.migrate(theme, to: 1) == theme)
        #expect(ThemeCodec.migrate(theme, to: 2) == theme)
    }
}
