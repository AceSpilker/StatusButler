import Foundation
import Testing

// T-054 收尾：WidgetKit 扩展 target 的组装契约——manifest target 名大小写不敏感查重
// （大小写不敏感 FS 上产物路径冲突是实测踩过的坑：butler/statusbutler 链接互踩）、
// appex Info.plist 模板钉死 WidgetKit 扩展最低要求、assemble-appex.sh dry-run 清单与参数白名单。

@Suite struct WidgetTargetAssemblyTests {

    // #filePath 回溯：Tests/StatusButlerCoreTests → Tests → 包根
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 从 Package.swift 抽 target 声明名（.target/.executableTarget/.testTarget 的 name: "..."）。
    /// 只认声明头紧跟的 name——dependencies 数组里的字符串、产品名都不会误捕
    private func extractTargetNames(from manifest: String) -> [String] {
        let pattern = #"\.(?:executableTarget|testTarget|target)\(\s*name:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(manifest.startIndex..., in: manifest)
        return regex.matches(in: manifest, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: manifest) else { return nil }
            return String(manifest[nameRange])
        }
    }

    // MARK: - target 名唯一性（防回归）

    @Test func packageTargetNamesAreUniqueCaseInsensitive() throws {
        let manifest = try String(contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
        let names = extractTargetNames(from: manifest)
        #expect(!names.isEmpty)

        var seen: Set<String> = []
        for name in names {
            let key = name.lowercased()
            #expect(!seen.contains(key), "target 名 '\(name)' 与既有 target 仅大小写不同——大小写不敏感 FS 上 .build 产物路径冲突")
            seen.insert(key)
        }
        // T-054 扩展 target 在册（迁移完成后不允许被静默摘除）
        #expect(names.contains("StatusButlerWidgets"))
    }

    @Test func widgetExecutableNameDiffersFromAppBinaryCaseInsensitive() throws {
        let manifest = try String(contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
        let names = extractTargetNames(from: manifest)
        let appex = try XCTUnwrapWidgetTarget(names: names)
        #expect(appex.lowercased() != "statusbutler", "appex 可执行名与主 App 产物名冲突（大小写不敏感）")
    }

    private func XCTUnwrapWidgetTarget(names: [String]) throws -> String {
        guard let appex = names.first(where: { $0.lowercased() == "statusbutlerwidgets" }) else {
            throw ExpectationFailedError.message("StatusButlerWidgets target 不在 Package.swift 声明里")
        }
        return appex
    }

    private struct ExpectationFailedError: Error {
        let message: String
        init(_ message: String) { self.message = message }
        static func message(_ text: String) -> ExpectationFailedError { ExpectationFailedError(text) }
    }

    // MARK: - appex Info.plist 模板

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let url = packageRoot().appending(path: relativePath)
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ExpectationFailedError("plist 反序列化失败: \(relativePath)")
        }
        return dict
    }

    @Test func appexTemplatePlistMatchesWidgetKitExtensionContract() throws {
        let plist = try loadPlist("Support/StatusButlerWidgets-Info.plist")
        let ext = plist["NSExtension"] as? [String: Any]
        #expect(ext?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        #expect(plist["CFBundlePackageType"] as? String == "XPC!")
        #expect(plist["CFBundleExecutable"] as? String == "StatusButlerWidgets")
        // 版本两键存在即可非空：组装期由 assemble-appex.sh 从主 plist 注入真值
        #expect((plist["CFBundleShortVersionString"] as? String)?.isEmpty == false)
        #expect((plist["CFBundleVersion"] as? String)?.isEmpty == false)
    }

    @Test func appexBundleIdentifierIsPrefixedByMainBundleIdentifier() throws {
        let main = try loadPlist("Support/Info.plist")
        let appex = try loadPlist("Support/StatusButlerWidgets-Info.plist")
        let mainID = try require(main["CFBundleIdentifier"] as? String, "主 Info.plist 缺 CFBundleIdentifier")
        let appexID = try require(appex["CFBundleIdentifier"] as? String, "appex 模板缺 CFBundleIdentifier")
        // macOS 要求 appex bundle id 以主 App id 为前缀（父子声明），否则拒载
        #expect(appexID.hasPrefix(mainID + "."))
        #expect(appexID != mainID)
    }

    private func require(_ value: String?, _ message: String) throws -> String {
        guard let value else { throw ExpectationFailedError(message) }
        return value
    }

    // MARK: - assemble-appex.sh dry-run 与参数白名单

    private struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runScript(_ arguments: [String]) throws -> ScriptResult {
        let script = packageRoot().appending(path: "scripts/assemble-appex.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    @Test func assembleAppexDryRunPrintsManifestWithoutTouchingDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "appex-dryrun-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try runScript([scratch.path, "release", "--dry-run"])
        #expect(result.status == 0)
        // 清单四行（相对 .app 根）：appex/binary/plist/extpoint——预检与实装共用同一输出
        #expect(result.stdout.contains("appex=Contents/PlugIns/StatusButlerWidgets.appex"))
        #expect(result.stdout.contains("binary=Contents/PlugIns/StatusButlerWidgets.appex/Contents/MacOS/StatusButlerWidgets"))
        #expect(result.stdout.contains("plist=Contents/PlugIns/StatusButlerWidgets.appex/Contents/Info.plist"))
        #expect(result.stdout.contains("extpoint=com.apple.widgetkit-extension"))
        // dry-run 承诺不写盘：scratch 路径下不该长出任何东西
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func assembleAppexScriptRejectsUnknownArgumentsAndMissingPath() throws {
        let badArg = try runScript(["/tmp/app-does-not-matter.app", "--bogus"])
        #expect(badArg.status == 2)
        #expect(badArg.stderr.contains("未知参数"))

        let missing = try runScript(["--dry-run"])
        #expect(missing.status == 2)
        #expect(missing.stderr.contains("缺少 <.app 路径>"))

        let extra = try runScript(["/tmp/a.app", "/tmp/b.app"])
        #expect(extra.status == 2)
        #expect(extra.stderr.contains("多余参数"))
    }
}
