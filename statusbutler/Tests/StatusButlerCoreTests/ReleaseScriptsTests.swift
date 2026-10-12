import Foundation
import Testing

// T-056a：发布链脚本契约——appcast 片段生成（ruby 子进程跑 fixture）、
// 参数白名单（未知参数/缺产物 exit 2，Mimosa 防注入纪律）、release-draft workflow 钉死。
// 脚本一律以子进程真实执行（非源码文本匹配的薄弱契约），fixture dist 用完即删

@Suite struct ReleaseScriptsTests {

    private struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    // #filePath 回溯仓库根：Tests/StatusButlerCoreTests → Tests → 包根 → 仓库根
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 子进程环境确定性：先抹掉两个占位变量（防宿主环境污染用例），再按需注入
    private func run(command: String, arguments: [String], env: [String: String] = [:]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SPARKLE_EDDSA_KEY")
        environment.removeValue(forKey: "DMG_DOWNLOAD_URL")
        for (key, value) in env { environment[key] = value }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // 先读完管道再 wait：缓冲区满时 wait 会死锁；本脚本输出量小，读端到 EOF 即返回
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// fixture dist：假 .app（Info.plist 版本元数据）+ 假 DMG（已知字节数）
    private func makeFixtureDist(version: String = "9.9.9", build: String = "42") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "appcast-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let contents = root.appending(path: "状态管家.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>状态管家</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            <key>LSMinimumSystemVersion</key><string>13.0</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        try Data("fixture dmg payload for appcast tests".utf8)
            .write(to: root.appending(path: "StatusButler-\(version).dmg"))
        return root
    }

    private var appcastScript: String {
        repoRoot().appending(path: "statusbutler/scripts/gen-appcast-fragments.rb").path
    }

    // MARK: - appcast 片段生成

    @Test func appcastFragmentContainsCoreSparkleFields() throws {
        let fixture = try makeFixtureDist()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let dmg = fixture.appending(path: "StatusButler-9.9.9.dmg")
        let length = try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int

        let result = try run(
            command: "/usr/bin/ruby",
            arguments: [appcastScript, fixture.path],
            env: [
                "SPARKLE_EDDSA_KEY": "MEUCIQDTESTSIGNATURE",
                "DMG_DOWNLOAD_URL": "https://dl.example.com/StatusButler-9.9.9.dmg",
            ]
        )
        #expect(result.status == 0)
        let xml = result.stdout
        #expect(xml.contains("<item>"))
        #expect(xml.contains("<title>状态管家 9.9.9</title>"))
        #expect(xml.contains("<pubDate>"))
        #expect(xml.contains("<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>"))
        // 三个占位替换位：url（env 注入）/ edSignature（env 注入）/ length（真实字节数）
        #expect(xml.contains("url=\"https://dl.example.com/StatusButler-9.9.9.dmg\""))
        #expect(xml.contains("sparkle:edSignature=\"MEUCIQDTESTSIGNATURE\""))
        #expect(xml.contains("length=\"\(length ?? -1)\""))
        #expect(xml.contains("type=\"application/x-apple-diskimage\""))
        #expect(xml.contains("sparkle:version=\"42\""))
        #expect(xml.contains("sparkle:shortVersionString=\"9.9.9\""))
        #expect(xml.contains("</item>"))
    }

    @Test func appcastFragmentWithoutEdDSAKeyWarnsAndExitsTwo() throws {
        let fixture = try makeFixtureDist()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = try run(command: "/usr/bin/ruby", arguments: [appcastScript, fixture.path])
        #expect(result.status == 2)
        // 缺 key = 无法生成可信条目：stdout 出注释警告，且不产出任何可用 enclosure
        #expect(result.stdout.contains("SPARKLE_EDDSA_KEY"))
        #expect(result.stdout.contains("警告"))
        #expect(!result.stdout.contains("sparkle:edSignature=\""))
    }

    @Test func appcastScriptRejectsUnknownArgumentsAndMissingDist() throws {
        let badArg = try run(command: "/usr/bin/ruby", arguments: [appcastScript, "--bogus"])
        #expect(badArg.status == 2)
        #expect(badArg.stderr.contains("未知参数"))
        let missing = try run(command: "/usr/bin/ruby", arguments: [appcastScript, "/nonexistent-dist-xyz"])
        #expect(missing.status == 2)
        #expect(missing.stderr.contains("dist 目录不存在"))
    }

    // MARK: - release-app.sh 参数白名单

    @Test func releaseAppScriptRejectsUnknownArgumentsBeforeAnyBuild() throws {
        let script = repoRoot().appending(path: "statusbutler/scripts/release-app.sh").path
        let result = try run(command: "/bin/bash", arguments: [script, "--bogus"])
        #expect(result.status == 2)
        #expect(result.stderr.contains("未知参数"))
        // 白名单校验先于一切构建/文件操作——本用例不产生 dist 副作用、不触发 swift build
    }

    // MARK: - release-draft workflow 契约

    @Test func releaseDraftWorkflowContractIsPinned() throws {
        let workflow = try String(
            contentsOf: repoRoot().appending(path: ".github/workflows/release-draft.yml"),
            encoding: .utf8
        )
        #expect(workflow.contains("tags: ['v*']"))          // 仅 v* tag push 触发自动链
        #expect(workflow.contains("workflow_dispatch"))     // 手动预检入口
        #expect(workflow.contains("swift test"))            // 发布前测试门与 ci.yml 同源
        #expect(workflow.contains("scripts/release-app.sh --no-publish"))
        #expect(workflow.contains("actions/upload-artifact@v4"))
        #expect(workflow.contains("if-no-files-found: error"))
    }

    // MARK: - release-draft publish 门控契约（T-056）

    @Test func releaseDraftPublishGatingContractIsPinned() throws {
        let workflow = try String(
            contentsOf: repoRoot().appending(path: ".github/workflows/release-draft.yml"),
            encoding: .utf8
        )
        // publish 必须是布尔输入且默认 false：tag push 永远只出草稿，正式链须手动显式勾选
        #expect(workflow.contains("publish:"))
        #expect(workflow.contains("type: boolean"))
        #expect(workflow.contains("default: false"))
        // 每个 publish 步骤都必须同时挂 workflow_dispatch + inputs.publish == true 双条件
        // （签名公证 / appcast / release 三步，缺一即漏门）
        let gatedConditions = workflow.components(
            separatedBy: "github.event_name == 'workflow_dispatch' && inputs.publish == true"
        ).count - 1
        #expect(gatedConditions >= 3)
        // 步骤名逐一标注"publish 门控"，评审一眼可辨哪些步骤进了正式链
        #expect((workflow.components(separatedBy: "publish 门控").count - 1) >= gatedConditions)
        // Secrets 缺失时回落 ad-hoc 并注明（::notice::），不得让草稿链硬失败
        #expect(workflow.contains("secrets.DEVELOPER_ID_APPLICATION_P12"))
        #expect(workflow.contains("::notice::未配置 DEVELOPER_ID_APPLICATION_P12"))
        // 公证走 notarytool + staple（Developer ID 路线）
        #expect(workflow.contains("notarytool submit"))
        #expect(workflow.contains("stapler staple"))
        // appcast：EdDSA key 从 secrets.SPARKLE_EDDSA_KEY，片段拼进 rss/channel 根元素
        #expect(workflow.contains("secrets.SPARKLE_EDDSA_KEY"))
        #expect(workflow.contains("gen-appcast-fragments.rb"))
        #expect(workflow.contains("<rss version=\"2.0\""))
        #expect(workflow.contains("</channel>"))
    }
}
