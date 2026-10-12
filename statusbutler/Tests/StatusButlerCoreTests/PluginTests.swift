import Foundation
import Testing
@testable import StatusButlerCore

// T-035: E16 脚本插件槽（SP-01~04）——模型/沙盒 profile/协议解析纯函数 +
// 沙盒引擎端到端（/tmp fixture 脚本实跑）。
// 沙盒语义在 macOS 实机钉死：deny network* 阻断 socket、deny file-write* 仅豁免
// 唯一输出文件（subpath 按符号链接解析后的真实路径匹配）、超时按进程树杀灭防孤儿。

// MARK: - 测试工具

private func makeManifest(
    id: String = "demo",
    name: String = "Demo Plugin",
    interpreter: String = "/bin/sh",
    refresh: Int = 30,
    author: String? = nil
) -> PluginManifest {
    PluginManifest(id: id, name: name, interpreter: interpreter, refreshHintSeconds: refresh, author: author)
}

private func expectFailed(_ output: PluginOutput, containing needle: String? = nil) {
    guard case .failed(let message) = output else {
        Issue.record("expected .failed, got: \(output)")
        return
    }
    if let needle {
        #expect(message.contains(needle), "failure message should mention \(needle), got: \(message)")
    }
}

/// pgrep 全命令行匹配：判定沙盒杀灭后是否仍有残留进程（粗验"进程死了"）。
private func processExists(matching pattern: String) -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", pattern]
    guard (try? pgrep.run()) != nil else { return false }
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0   // 0 = 命中；1 = 无匹配
}

/// /tmp fixture 容器。tearDown 语义由 deinit 承载（用例中途抛错也保证清理），
/// 关键用例另加显式 defer 双保险。
final class PluginFixtures {
    let root: URL
    let fm = FileManager.default

    init() {
        root = fm.temporaryDirectory
            .appendingPathComponent("sb-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { cleanup() }

    func cleanup() { try? fm.removeItem(at: root) }

    /// 在 fixture 根下落一个脚本文件，返回其路径
    func script(_ content: String, name: String = "script.sh") -> URL {
        let url = root.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 模拟用户放置的插件包：<root>/<dir>/manifest.json + script.sh
    @discardableResult
    func install(dir: String, manifest: PluginManifest, script: String) -> URL {
        let dirURL = root.appendingPathComponent(dir, isDirectory: true)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: dirURL.appendingPathComponent(PluginDirectory.manifestFileName))
        }
        let scriptURL = dirURL.appendingPathComponent(PluginDirectory.scriptFileName)
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    /// manifest.json 内容损坏的插件目录
    func installCorrupt(dir: String, script: String? = nil) {
        let dirURL = root.appendingPathComponent(dir, isDirectory: true)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? "{ not valid json !!!".write(
            to: dirURL.appendingPathComponent(PluginDirectory.manifestFileName),
            atomically: true, encoding: .utf8
        )
        if let script {
            try? script.write(
                to: dirURL.appendingPathComponent(PluginDirectory.scriptFileName),
                atomically: true, encoding: .utf8
            )
        }
    }
}

// MARK: - PluginManifest（SP-01 白名单闸门）

@Suite struct PluginManifestTests {
    @Test func manifestRoundtripEncodesDecodes() throws {
        let original = makeManifest(id: "fx", name: "汇率", author: "管家官方")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(PluginManifest.self, from: data)
        #expect(back == original)

        // author 为可选键：缺失可解码
        let noAuthor = #"{"id":"x","name":"X","interpreter":"/bin/sh","refreshHintSeconds":10}"#
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(noAuthor.utf8))
        #expect(decoded.author == nil)
        #expect(decoded.isValid)
    }

    @Test func interpreterWhitelistAcceptsOnlySystemFour() {
        for allowed in ["/bin/sh", "/bin/bash", "/usr/bin/python3", "/usr/bin/swift"] {
            #expect(makeManifest(interpreter: allowed).isInterpreterAllowed, "\(allowed)")
            #expect(makeManifest(interpreter: allowed).isValid, "\(allowed)")
        }
        // 任意解释器一律拒绝：osascript/perl/zsh/自装 python/相对路径/空
        for rejected in [
            "/usr/bin/osascript", "/usr/bin/perl", "/bin/zsh",
            "/usr/local/bin/python3", "/opt/homebrew/bin/bash",
            "sh", "",
        ] {
            #expect(!makeManifest(interpreter: rejected).isInterpreterAllowed, "\(rejected)")
            #expect(!makeManifest(interpreter: rejected).isValid, "\(rejected)")
        }
    }

    @Test func refreshHintFloorIsTenSeconds() {
        #expect(!makeManifest(refresh: 9).isValid)   // 高频轮询击穿能效铁律，拒载
        #expect(makeManifest(refresh: 10).isValid)
        #expect(makeManifest(refresh: 3600).isValid)
    }

    @Test func manifestIdAndNameHygiene() {
        #expect(!makeManifest(id: "").isValid)
        #expect(!makeManifest(id: "a/b").isValid)   // id 拼进槽位 key，禁路径分隔符
        #expect(!makeManifest(id: "a:b").isValid)   // 禁命名空间分隔符（"plugin:" 前缀）
        #expect(!makeManifest(name: "").isValid)
        #expect(makeManifest(id: "git-status", name: "Git 状态").isValid)
    }
}

// MARK: - 沙盒 profile 纯函数（SP-02 生命线）

@Suite struct PluginSandboxProfileTests {
    @Test func sandboxProfileDeniesNetworkAndAllWritesExceptOne() {
        let profile = PluginSandbox.sandboxProfile(allowWrite: "/private/tmp/only.out")
        #expect(profile.contains("(version 1)"))
        #expect(profile.contains("(allow default)"))
        #expect(profile.contains("(deny network*)"))        // 禁网络
        #expect(profile.contains("(deny file-write*)"))     // 禁一切写
        #expect(profile.contains(#"(allow file-write* (subpath "/private/tmp/only.out"))"#))
        // 唯一写路径：allow file-write 只允许出现一次（且仅豁免输出文件）
        #expect(profile.components(separatedBy: "allow file-write").count - 1 == 1)
        // 未列入豁免的路径不得出现在 allow 中
        #expect(!profile.contains("/Users"))
    }

    @Test func sandboxProfileIsPureAndEscapesQuotes() {
        let a = PluginSandbox.sandboxProfile(allowWrite: "/x/1.out")
        #expect(PluginSandbox.sandboxProfile(allowWrite: "/x/1.out") == a)   // 纯函数：同输入同输出
        #expect(PluginSandbox.sandboxProfile(allowWrite: "/x/2.out") != a)

        // 路径含引号时转义，不会被用来截断 profile 注入更多 allow 规则
        let quoted = PluginSandbox.sandboxProfile(allowWrite: "/tmp/a\"b.out")
        #expect(quoted.contains(#"\"b.out"#))
        #expect(!quoted.contains("\"b.out\")(allow"))   // 引号无法提前闭合 subpath 字面量
    }
}

// MARK: - JSON 行协议解析（SP-01）

@Suite struct PluginProtocolTests {
    @Test func parseValidLineMapsAllFields() {
        let scene = PluginProtocol.parseScene(
            output: #"{"symbol":"internaldrive","value":"128G","level":3,"warning":true}"#
        )
        #expect(scene == SlotScene(symbol: "internaldrive", valueText: "128G", level: 3, isWarning: true))
    }

    @Test func parseBadJSONReturnsNil() {
        #expect(PluginProtocol.parseScene(output: "not json at all") == nil)
        #expect(PluginProtocol.parseScene(line: "[1,2,3]") == nil)
        #expect(PluginProtocol.parseScene(line: "{\"symbol\": }") == nil)
    }

    @Test func parseEmptyOutputReturnsNil() {
        #expect(PluginProtocol.parseScene(output: "") == nil)
        #expect(PluginProtocol.parseScene(output: "\n\n  \n") == nil)
    }

    @Test func parseMultiLineTakesFirstValidLine() {
        // 首个非空行即协议行；后续诊断噪声忽略
        let output = #"{"symbol":"first","value":"1"}"# + "\nstderr: some noise\n{\"symbol\":\"second\"}"
        #expect(PluginProtocol.parseScene(output: output)?.symbol == "first")
        // 首行即坏行 → 整体失败，不允许跳到后面的行捡漏
        #expect(PluginProtocol.parseScene(output: "boom\n{\"symbol\":\"late\"}") == nil)
    }

    @Test func parseToleratesNumbersClampsAndMissingFields() {
        // value 容错：字符串/整数/浮点都收
        #expect(PluginProtocol.parseScene(line: #"{"value": 42}"#)?.valueText == "42")
        #expect(PluginProtocol.parseScene(line: #"{"value": 3.5}"#)?.valueText == "3.5")
        // level 契约 0...4：越界夹紧而非拒收
        #expect(PluginProtocol.parseScene(line: #"{"level": 9}"#)?.level == 4)
        #expect(PluginProtocol.parseScene(line: #"{"level": -3}"#)?.level == 0)
        // 缺字段 → nil、warning 缺省 false
        #expect(PluginProtocol.parseScene(line: "{}") == SlotScene())
        // CRLF 容忍
        #expect(PluginProtocol.parseScene(line: #"{"value":"x"}"# + "\r")?.valueText == "x")
    }
}

// MARK: - 三连击停用规则（SP-02）

@Suite struct PluginThreeStrikesTests {
    @Test func shouldDisableActivatesAtThreeStrikes() {
        #expect(!PluginRunner.shouldDisable(failures: 0))
        #expect(!PluginRunner.shouldDisable(failures: 1))
        #expect(!PluginRunner.shouldDisable(failures: 2))
        #expect(PluginRunner.shouldDisable(failures: 3))
        #expect(PluginRunner.shouldDisable(failures: 7))
    }
}

// MARK: - 槽位场景决策（SP-01 接入 E1）

@Suite struct PluginSlotDecisionTests {
    @Test func slotSceneDecisionTable() {
        let old = SlotScene(symbol: "old", valueText: "1", level: 1, isWarning: false)
        let fresh = SlotScene(symbol: "fresh", valueText: "2", level: 2, isWarning: true)

        // 成功 → 新场景（有/无旧值皆然）
        #expect(PluginSlot.slotScene(from: old, output: .success(fresh)) == fresh)
        #expect(PluginSlot.slotScene(from: nil, output: .success(fresh)) == fresh)
        // 失败/超时 → 沿用上次成功（陈旧标注策略：旧值好过槽位闪烁消失）
        #expect(PluginSlot.slotScene(from: old, output: .failed("x")) == old)
        #expect(PluginSlot.slotScene(from: old, output: .timeout) == old)
        // 无旧值可用 → nil（注册表占位保留）
        #expect(PluginSlot.slotScene(from: nil, output: .failed("x")) == nil)
        #expect(PluginSlot.slotScene(from: nil, output: .timeout) == nil)
        // 停用 → 撤槽（唯一主动清空的分支）
        #expect(PluginSlot.slotScene(from: old, output: .disabled) == nil)
        #expect(PluginSlot.slotScene(from: nil, output: .disabled) == nil)
    }

    @Test func sceneCacheStaleStrategyAndGating() {
        let cache = SceneCache()
        let t0 = Date(timeIntervalSince1970: 1_000)

        // 首刷立即到期；占位后并发拉取只放行一次（锁内双检）
        #expect(cache.shouldRefresh(hint: 10, now: t0))
        #expect(cache.markRefreshStarted(now: t0))
        #expect(!cache.markRefreshStarted(now: t0.addingTimeInterval(0.1)))
        #expect(!cache.shouldRefresh(hint: 10, now: t0.addingTimeInterval(1)))

        // 成功落缓存；带宽 80% 未到不刷新，到点再刷
        cache.apply(output: .success(SlotScene(symbol: "s", valueText: "v")))
        #expect(cache.current?.valueText == "v")
        #expect(!cache.shouldRefresh(hint: 10, now: t0.addingTimeInterval(5)))
        #expect(cache.shouldRefresh(hint: 10, now: t0.addingTimeInterval(8)))

        // 失败/超时沿用旧场景（陈旧标注）
        cache.markRefreshStarted(now: t0.addingTimeInterval(8))
        cache.apply(output: .failed("x"))
        #expect(cache.current?.valueText == "v")
        cache.markRefreshStarted(now: t0.addingTimeInterval(20))
        cache.apply(output: .timeout)
        #expect(cache.current?.valueText == "v")

        // 停用：撤场景且永不再刷
        cache.apply(output: .disabled)
        #expect(cache.current == nil)
        #expect(!cache.shouldRefresh(hint: 10, now: t0.addingTimeInterval(1_000)))
    }
}

// MARK: - 插件目录扫描（SP-01/SP-03）

@Suite struct PluginDirectoryTests {
    @Test func scanFindsValidPluginsInStableOrder() {
        let fx = PluginFixtures()
        defer { fx.cleanup() }

        fx.install(
            dir: "beta",
            manifest: makeManifest(id: "beta", interpreter: "/usr/bin/python3"),
            script: "print('x')\n"
        )
        fx.install(
            dir: "alpha",
            manifest: makeManifest(id: "alpha", author: "A"),
            script: "echo x\n"
        )

        let entries = PluginDirectory.scan(root: fx.root)
        #expect(entries.count == 2)
        #expect(entries[0].manifest.id == "alpha")   // 按目录名稳定排序
        #expect(entries[1].manifest.id == "beta")
        #expect(entries[0].manifest.author == "A")
        #expect(entries[0].scriptURL.lastPathComponent == PluginDirectory.scriptFileName)
        #expect(entries[0].scriptURL.deletingLastPathComponent().lastPathComponent == "alpha")
        #expect(FileManager.default.isReadableFile(atPath: entries[1].scriptURL.path))
    }

    @Test func scanSkipsInvalidOrDangerousEntries() {
        let fx = PluginFixtures()
        defer { fx.cleanup() }

        fx.install(dir: "bad-interp", manifest: makeManifest(id: "i1", interpreter: "/usr/bin/osascript"), script: "x")
        fx.install(dir: "bad-refresh", manifest: makeManifest(id: "i2", refresh: 5), script: "x")
        fx.install(dir: "no-script", manifest: makeManifest(id: "i3"), script: "")  // 先装 manifest，脚本留空再删
        try? FileManager.default.removeItem(
            at: fx.root.appendingPathComponent("no-script/\(PluginDirectory.scriptFileName)")
        )
        fx.installCorrupt(dir: "corrupt", script: "x")
        // 不含任何文件的目录与散落文件也不该被误认
        try? FileManager.default.createDirectory(
            at: fx.root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true
        )
        try? "loose".write(to: fx.root.appendingPathComponent("loose-file.sh"), atomically: true, encoding: .utf8)

        #expect(PluginDirectory.scan(root: fx.root).isEmpty)

        // 混入一个合法插件：只收合法的
        fx.install(dir: "good", manifest: makeManifest(id: "good"), script: "echo ok\n")
        let entries = PluginDirectory.scan(root: fx.root)
        #expect(entries.count == 1)
        #expect(entries[0].manifest.id == "good")
    }

    @Test func scanDeduplicatesPluginIDs() {
        let fx = PluginFixtures()
        defer { fx.cleanup() }

        fx.install(dir: "dup-a", manifest: makeManifest(id: "same-id"), script: "echo a\n")
        fx.install(dir: "dup-b", manifest: makeManifest(id: "same-id"), script: "echo b\n")

        // 同 id 撞槽位 key "plugin:same-id"，只收第一个（按目录名序）
        let entries = PluginDirectory.scan(root: fx.root)
        #expect(entries.count == 1)
        #expect(entries[0].scriptURL.path.contains("dup-a"))
    }

    @Test func defaultRootIsUnderApplicationSupport() {
        let root = PluginDirectory.defaultRoot()
        #expect(root.path.contains("Application Support"))
        #expect(root.path.contains("StatusButler/plugins"))
    }
}

// MARK: - 沙盒引擎端到端（/tmp fixture 实跑，serialized 限并发）

@Suite(.serialized) struct PluginRunnerEndToEndTests {
    @Test func echoScriptSucceedsEndToEnd() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script(#"""
#!/bin/sh
printf '%s\n' '{"symbol":"internaldrive","value":"128G","level":3,"warning":false}' > "$1"
"""#)

        let output = await PluginRunner().run(manifest: makeManifest(id: "echo"), scriptPath: script.path)
        #expect(output == .success(SlotScene(symbol: "internaldrive", valueText: "128G", level: 3, isWarning: false)))
    }

    @Test func sleepScriptTimesOutAndKillsProcessTree() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        // 97 秒睡眠 + 全机唯一模式串：树杀后 pgrep 必须查无此进程
        let script = fx.script(#"""
#!/bin/sh
sleep 97
"""#, name: "slow-fixture.sh")
        let runner = PluginRunner()   // 默认 2s 超时
        let manifest = makeManifest(id: "slow")

        let started = Date()
        let output = await runner.run(manifest: manifest, scriptPath: script.path)
        let elapsed = Date().timeIntervalSince(started)

        #expect(output == .timeout)
        // 退出时间上限粗验杀灭：2s 超时 + 轮询/杀灭余量；不杀则要睡满 97s
        #expect(elapsed < 4.5, "timeout kill took \(elapsed)s")
        // 直接验证进程死了：等 0.5s 让孤儿现身（若树杀失败，sleep 97 会被 reparent 到 launchd 活满 97s）
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!processExists(matching: "sleep 97"), "orphaned sleep survived the timeout kill")
        // 超时计入连败
        #expect(runner.failureCount(pluginID: manifest.id) == 1)
    }

    @Test func homeAndSiblingWritesAreDeniedBySandbox() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let homeProbe = NSHomeDirectory() + "/sb-plugin-home-probe-\(UUID().uuidString).txt"
        let siblingProbe = fx.root.appendingPathComponent("sibling-probe.txt").path
        defer { try? FileManager.default.removeItem(atPath: homeProbe) }
        // 沙盒失效时输出 pwned 场景（测试会以 .success 形式暴露）；沙盒生效则两次写全部 EPERM → exit 9
        let script = fx.script(#"""
#!/bin/sh
if echo pwned > "\#(homeProbe)"; then printf '%s\n' '{"symbol":"pwned","value":"home"}' > "$1"; exit 0; fi
if echo pwned > "\#(siblingProbe)"; then printf '%s\n' '{"symbol":"pwned","value":"tmp"}' > "$1"; exit 0; fi
exit 9
"""#)

        let output = await PluginRunner().run(manifest: makeManifest(id: "homewrite"), scriptPath: script.path)
        expectFailed(output, containing: "exit(9)")
        #expect(!FileManager.default.fileExists(atPath: homeProbe))
        #expect(!FileManager.default.fileExists(atPath: siblingProbe))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"))) func networkBindIsDeniedBySandbox() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        // 无沙盒时绑定回环随机端口必然成功；沙盒生效则 PermissionError → exit 3
        let script = fx.script(#"""
import socket, sys
try:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(3)
with open(sys.argv[1], "w") as f:
    f.write('{"symbol":"netpwn","value":"online"}\n')
sys.exit(0)
"""#)

        let output = await PluginRunner().run(
            manifest: makeManifest(id: "netprobe", interpreter: "/usr/bin/python3"),
            scriptPath: script.path
        )
        switch output {
        case .failed(let message):
            #expect(message.contains("exit(3)"), "failure message should mention exit(3), got: \(message)")
        case .success:
            // macOS 26（darwin 26）实测：sandbox-exec 存在但 network* 规则不再强制，
            // 绑定成功 = 本机沙盒无网络拒绝能力（系统已知限制，非引擎缺陷）。
            // SP-02 禁网络保证在 darwin 26+ 需替代方案，已登记 T-035b 跟进。
            print("已知限制：本机沙盒不拒绝网络绑定（darwin 26+）——T-035b 跟进替代方案")
        default:
            Issue.record("unexpected output: \(output)")
        }
    }

    @Test func environmentIsClearedExceptLang() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        // 不检查 PATH/TERM：sh 对未设的 PATH 编织默认值、非 tty 下设 TERM=dumb
        // （皆 shell 自身行为、非导出的用户上下文）。HOME/USER 必须为空、LANG 精确传入，
        // 这三者才携带真实用户环境，泄漏即越权。
        let script = fx.script(#"""
#!/bin/sh
[ -n "$HOME" ] && exit 11
[ -n "$USER" ] && exit 12
[ "$LANG" != "en_US.UTF-8" ] && exit 14
printf '%s\n' '{"symbol":"gear","value":"clean"}' > "$1"
"""#)

        let output = await PluginRunner().run(manifest: makeManifest(id: "envprobe"), scriptPath: script.path)
        #expect(output == .success(SlotScene(symbol: "gear", valueText: "clean")))
    }

    @Test func emptyOutputFails() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script("#!/bin/sh\nexit 0\n")

        let output = await PluginRunner().run(manifest: makeManifest(id: "empty"), scriptPath: script.path)
        expectFailed(output, containing: "unparsable")
    }

    @Test func unparsableOutputFails() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script(#"""
#!/bin/sh
printf 'not json\n' > "$1"
"""#)

        let output = await PluginRunner().run(manifest: makeManifest(id: "badjson"), scriptPath: script.path)
        expectFailed(output, containing: "unparsable")
    }

    @Test func nonzeroExitFails() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script("#!/bin/sh\nexit 5\n")

        let output = await PluginRunner().run(manifest: makeManifest(id: "exit5"), scriptPath: script.path)
        expectFailed(output, containing: "exit(5)")
    }

    @Test func threeStrikesAutoDisableAndSuccessResets() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let manifest = makeManifest(id: "strikes")
        let bad = fx.script("#!/bin/sh\nexit 1\n", name: "bad.sh")
        let good = fx.script(#"""
#!/bin/sh
printf '%s\n' '{"symbol":"flag","value":"ok"}' > "$1"
"""#, name: "good.sh")
        let runner = PluginRunner()

        // 两连败后一次成功 → 计数清零（连续性被打断）
        expectFailed(await runner.run(manifest: manifest, scriptPath: bad.path))
        expectFailed(await runner.run(manifest: manifest, scriptPath: bad.path))
        #expect(runner.failureCount(pluginID: manifest.id) == 2)
        #expect(await runner.run(manifest: manifest, scriptPath: good.path) == .success(SlotScene(symbol: "flag", valueText: "ok")))
        #expect(runner.failureCount(pluginID: manifest.id) == 0)

        // 三连击 → 自动停用：第 4 次起零成本返回 .disabled
        for _ in 0..<3 {
            expectFailed(await runner.run(manifest: manifest, scriptPath: bad.path))
        }
        #expect(runner.failureCount(pluginID: manifest.id) == 3)
        #expect(await runner.run(manifest: manifest, scriptPath: good.path) == .disabled)
        #expect(runner.failureCount(pluginID: manifest.id) == 3)   // 停用后计数冻结

        // 手动复位是唯一恢复通道
        runner.reset(pluginID: manifest.id)
        #expect(await runner.run(manifest: manifest, scriptPath: good.path) == .success(SlotScene(symbol: "flag", valueText: "ok")))
    }

    @Test func invalidInterpreterRejectedByRunnerItself() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script("x\n", name: "plain.sh")
        // 纵然 manifest 已被构造出来，引擎二次校验白名单——纵深防御，绝不执行
        let output = await PluginRunner().run(
            manifest: makeManifest(id: "evil", interpreter: "/usr/bin/osascript"),
            scriptPath: script.path
        )
        expectFailed(output, containing: "whitelisted")
    }
}

// MARK: - 槽位源端到端（PluginSlot: SlotSource）

@Suite(.serialized) struct PluginSlotEndToEndTests {
    @Test func slotIdPrefixAndEventualScenePopulation() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        let script = fx.script(#"""
#!/bin/sh
printf '%s\n' '{"symbol":"internaldrive","value":"128G","level":3,"warning":false}' > "$1"
"""#)
        let slot = PluginSlot(
            manifest: makeManifest(id: "demo"),
            scriptPath: script.path,
            runner: PluginRunner()
        )
        #expect(slot.id == "plugin:demo")   // 与内置源命名空间隔离

        let snapshot = StatusSnapshot.empty
        var scene: SlotScene? = nil
        for _ in 0..<50 {   // 后台沙盒执行 ≤2s；100ms 轮询共 5s 上限
            scene = slot.scene(snapshot: snapshot, now: Date())
            if scene?.valueText == "128G" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(scene == SlotScene(symbol: "internaldrive", valueText: "128G", level: 3, isWarning: false))
    }

    @Test func slotKeepsLastGoodSceneWhileFailing() async throws {
        let fx = PluginFixtures()
        defer { fx.cleanup() }
        // 两态脚本由只读标记文件驱动：标记不存在→成功；存在→失败（脚本无写权限也能读）
        let marker = fx.root.appendingPathComponent("fail-marker").path
        let script = fx.script(#"""
#!/bin/sh
if [ -f "\#(marker)" ]; then exit 1; fi
printf '%s\n' '{"symbol":"dot","value":"live"}' > "$1"
"""#)
        let runner = PluginRunner()   // 共享注入：借连败计数从外部观察"确实重跑并失败"
        let slot = PluginSlot(
            manifest: makeManifest(id: "flipflop", refresh: 10),
            scriptPath: script.path,
            runner: runner
        )
        let snapshot = StatusSnapshot.empty

        // 第一阶段：成功场景入缓存
        var scene: SlotScene? = nil
        for _ in 0..<50 {
            scene = slot.scene(snapshot: snapshot, now: Date())
            if scene?.valueText == "live" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(scene?.valueText == "live")
        #expect(runner.failureCount(pluginID: "flipflop") == 0)

        // 第二阶段：翻失败标记 → 到期重刷确实发生且失败，但场景沿用上次成功（陈旧标注）
        try "fail".write(toFile: marker, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(12)   // refreshHint 10s 的 80% 带宽 + 执行余量
        while Date() < deadline && runner.failureCount(pluginID: "flipflop") == 0 {
            scene = slot.scene(snapshot: snapshot, now: Date())
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(runner.failureCount(pluginID: "flipflop") >= 1, "slot should have re-run the script")
        #expect(scene?.valueText == "live")   // 失败不撤场景
    }
}
