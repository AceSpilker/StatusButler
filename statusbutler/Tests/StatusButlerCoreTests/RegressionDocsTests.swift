import Foundation
import Testing

// T-057：全量回归脚本 + 文档终稿契约。
// 脚本类契约以子进程真实执行（--help / 未知参数），内容类契约读文件钉死关键锚点——
// 与 ReleaseScriptsTests 同一纪律：能跑就不做文本匹配，文本钉死只用于不便全量执行的步骤清单。

@Suite struct RegressionDocsTests {

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

    private func run(command: String, arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // 先读完管道再 wait：缓冲区满时 wait 会死锁
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appending(path: relativePath), encoding: .utf8)
    }

    private var regressionScript: String {
        repoRoot().appending(path: "statusbutler/scripts/full-regression.sh").path
    }

    // MARK: - 回归脚本契约（子进程真实执行）

    @Test func regressionScriptHelpContract() throws {
        let result = try run(command: "/bin/bash", arguments: [regressionScript, "--help"])
        #expect(result.status == 0)
        let help = result.stdout
        // 用法与步骤清单齐全：七步全列 + PASS/FAIL 语义 + 日志落点
        #expect(help.contains("用法: bash scripts/full-regression.sh"))
        #expect(help.contains("swift build"))
        #expect(help.contains("swift test"))
        #expect(help.contains("第 1 遍"))
        #expect(help.contains("第 2 遍"))
        #expect(help.contains("build-app.sh release no-open"))
        #expect(help.contains("Info.plist"))
        #expect(help.contains("butler CLI"))
        #expect(help.contains("任一 FAIL"))
        #expect(help.contains("退出码 1"))
    }

    @Test func regressionScriptRejectsUnknownArguments() throws {
        let result = try run(command: "/bin/bash", arguments: [regressionScript, "--bogus"])
        #expect(result.status == 2)
        #expect(result.stderr.contains("未知参数"))
        // 白名单校验先于一切构建/文件操作——不产生任何副作用输出
        #expect(!result.stdout.contains("PASS"))
    }

    /// 不便在用例里全量执行的步骤，钉死脚本源内的关键骨架（与 workflow 钉死测试同风格）
    @Test func regressionScriptPinsCoreStepSkeleton() throws {
        let script = try read("statusbutler/scripts/full-regression.sh")
        #expect(script.contains("swift build -c release"))                 // 双配置构建
        #expect(script.contains("swift build\n"))                          // debug 默认配置
        #expect(script.contains("第 1 遍"))                                 // 测试两遍抓偶发
        #expect(script.contains("第 2 遍"))
        #expect(script.contains("release no-open"))                        // 组包复用既有脚本
        #expect(script.contains("PlistBuddy"))                             // Info.plist 键断言
        #expect(script.contains("Signature=adhoc"))                        // ad-hoc 签名断言
        #expect(script.contains("codesign --verify"))                      // 签名可校验
        #expect(script.contains("status --json"))                          // CLI 冒烟：无 App 码 2
        #expect(script.contains("{\"error\":\"app-not-running\"}"))        // 码 2 钉死载荷（AU-04）
        #expect(script.contains("restore_snapshot"))                       // 用户真实快照零破坏兜底
        // 任一 FAIL 即 exit 1 的总裁决
        #expect(script.contains("[[ $FAIL_COUNT -eq 0 ]]"))
    }

    // MARK: - 发布说明（0.1.0 双语）

    @Test func releaseNotesBilingualContract() throws {
        let zh = try read("release-notes/0.1.0/zh-Hans.md")
        #expect(zh.contains("# 状态管家 StatusButler 0.1.0"))
        #expect(zh.contains("## 这是什么"))
        #expect(zh.contains("## 安装"))
        #expect(zh.contains("## 已知限制"))
        // 任务钉死的两条已知限制：ad-hoc 首开放行 + 沙盒网络限制
        #expect(zh.contains("ad-hoc"))
        #expect(zh.contains("右键"))
        #expect(zh.contains("沙盒"))
        #expect(zh.contains("network*"))
        #expect(zh.contains("butler status --json"))                      // CLI 示例与 README 同源
        #expect(zh.contains("butler volume 50"))

        let en = try read("release-notes/0.1.0/en.md")
        #expect(en.contains("# StatusButler 0.1.0"))
        #expect(en.contains("## What it is"))
        #expect(en.contains("## Installation"))
        #expect(en.contains("## Known Limitations"))
        #expect(en.contains("ad-hoc"))
        #expect(en.contains("sandbox"))
        #expect(en.contains("network*"))
        #expect(en.contains("butler status --json"))
    }

    // MARK: - README 关键小节

    @Test func readmeCoversBuildRunCliTestDocsAndContribution() throws {
        let readme = try read("README.md")
        #expect(readme.contains("## 构建"))
        #expect(readme.contains("## 运行"))
        #expect(readme.contains("## CLI"))
        #expect(readme.contains("## 测试"))
        #expect(readme.contains("## 架构"))
        #expect(readme.contains("## 贡献"))
        #expect(readme.contains("## 许可"))
        // 真实现状示例与回归入口
        #expect(readme.contains("butler status --json"))
        #expect(readme.contains("butler volume 50"))
        #expect(readme.contains("full-regression.sh"))
        #expect(readme.contains("455"))
        // 文档导航更新至全部页（含新增 A13）
        #expect(readme.contains("a13-usage.html"))
        #expect(readme.contains("a12-productivity-platform.html"))
        #expect(readme.contains("c1-plan.html"))
        #expect(readme.contains("01-overview.html"))
        // 过时占位已删
        #expect(!readme.contains("设计完备，进入编码准备"))
        #expect(!readme.contains("待定（计划随首个可运行版本一同确定）"))
    }

    // MARK: - AGENTS 实战经验

    @Test func agentsExperienceLogHasFivePlusEntriesWithTaskRefs() throws {
        let agents = try read("AGENTS.md")
        let section = try #require(agents.components(separatedBy: "## 实战经验").last)
        // 条目形如 "- **标题**：…"，至少 5 条（当前 6 条）
        let entries = section
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("- **") }
        #expect(entries.count >= 5)
        // 任务钉死的五个主题全部落档
        for keyword in ["大小写不敏感", "union", "WindowServer", "network*", "dropFirst"] {
            #expect(section.contains(keyword), "实战经验缺主题：\(keyword)")
        }
        // 每条都带出处任务号（(T-xxx)），可回溯
        for entry in entries {
            #expect(entry.contains("(T-"), "经验条目缺出处任务号：\(entry.prefix(30))")
        }
    }

    // MARK: - A13 用户使用指南页

    @Test func a13UsagePageCoversAllUserFacingSections() throws {
        let page = try read("docs/a13-usage.html")
        // 必备小节：菜单栏/弹层/设置/槽位/CLI/小组件/已知限制/FAQ
        for anchor in [
            "<h2>三十秒上手", "<h2>菜单栏图标", "<h2>弹层面板", "<h2>设置中心",
            "<h2>底部槽位", "<h2>命令行", "<h2>桌面小组件", "<h2>已知限制", "<h2>常见问题（FAQ）",
        ] {
            #expect(page.contains(anchor), "A13 缺小节：\(anchor)")
        }
        // 已知限制必须含任务钉死的两条 + 小组件"即将"徽标口径
        #expect(page.contains("ad-hoc"))
        #expect(page.contains("沙盒"))
        #expect(page.contains("即将"))
        // CLI 退出码表与示例和真实实现同源（0/1/2/3 + app-not-running 载荷）
        #expect(page.contains("butler status --json"))
        #expect(page.contains("app-not-running"))
        #expect(page.contains("butler volume 50"))
        // 复用 docs 模板风格（内联 CSS 变量与 a1 一致）
        #expect(page.contains("--brand:#0a7d6f"))
        #expect(page.contains("A13 / User Guide"))
    }
}
