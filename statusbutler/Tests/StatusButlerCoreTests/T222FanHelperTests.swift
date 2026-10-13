import Foundation
import Testing

@testable import StatusButlerCore

// T-222 风扇特权 Helper（代码半场）：真二进制进程级契约测试 + 客户端白名单/协议测试。
// 真二进制经 swiftc 现场编译（与 swift build 同工具链前提；每测试进程编译一次），
// 只行使零 SMC 副作用的协议路径（ping/坏行/未知 action/白名单拒绝/EOF）——
// 带值的 set 往返会真写 SMC（Intel 用户态可写），真跑验证归安装半场（用户管理员确认后）。
// FanHelperClient 走假 helper 脚本驱动全链路（JSON 行发射/应答解析/缺失降级）。

// MARK: - 真二进制编译缓存

private enum RealFanHelper {
    static let binary: URL? = compile()

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func locateSwiftC() -> URL? {
        // PATH 优先（CI/开发者先 export swiftly——CLT swiftc 在 swiftly 环境有
        // SwiftBridging 冲突，见 build-fanhelper.sh 同款解析纪律），回退常规落位
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = path.split(separator: ":").map(String.init)
            + ["\(home)/.swiftly/bin/swiftc", "/usr/bin/swiftc", "/usr/local/bin/swiftc"]
        for candidate in candidates where candidate.hasSuffix("/swiftc") {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func compile() -> URL? {
        guard let swiftc = locateSwiftC() else { return nil }
        let source = packageRoot().appending(path: "Support/FanHelper/main.swift")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "statusbutler-fanhelper-test")
        let process = Process()
        process.executableURL = swiftc
        // -Onone：协议契约测试不测性能，免优化编译把 CPU 峰值压到最低——
        // 满载 -O 编译曾把并行的插件超时杀灭用例（50ms 轮询窗口）挤出时间片
        process.arguments = ["-Onone", source.path, "-o", output.path]
        // swiftly 代理用 SWIFTLY_PROXY_IN_PROGRESS 防套娃：swift test 进程继承它，
        // 不剥掉的话子进程 swiftc 直接拒绝（"Circular swiftly proxy invocation"）
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFTLY_PROXY_IN_PROGRESS")
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return process.terminationStatus == 0 ? output : nil
    }
}

/// 跑一次真 helper：喂 stdin（含收尾 EOF），收齐 stdout/stderr/退出码
private func runRealHelper(_ input: String) throws -> (status: Int32, stdout: String, stderr: String) {
    let binary = try #require(RealFanHelper.binary, "swiftc 编译 helper 失败（工具链不可用？）")
    let process = Process()
    process.executableURL = binary
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    stdinPipe.fileHandleForWriting.write(Data((input + "\n").utf8))
    try stdinPipe.fileHandleForWriting.close()  // EOF：helper 的正常退出信号
    // 先读干管道再 wait：缓冲区满时 wait 死锁（仓库既有脚本契约用例同纪律）
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(decoding: stdoutData, as: UTF8.self),
        String(decoding: stderrData, as: UTF8.self)
    )
}

// MARK: - 键白名单（客户端侧纯函数）

@Suite struct T222FanHelperKeysTests {

    @Test func whitelistAcceptsOnlyFanDomainKeys() {
        // 风扇域全量放行：模式键 + F0~F7Md
        for key in ["FS!", "F0Md", "F3Md", "F7Md"] {
            #expect(FanHelperKeys.isWriteAllowed(key: key), "应放行 \(key)")
        }
        // 红线二：充电/电源域（BC*/AC*）、温度读键、越界序号、残缺形态一律拒绝
        for key in ["TC0P", "TG0P", "BC1C", "ACEN", "CH0I", "F8Md", "F10Md", "FMd",
                    "Md", "F0Ac", "F0Mx", "FS", "FS! ", "F0MD", "", "f0md"] {
            #expect(!FanHelperKeys.isWriteAllowed(key: key), "应拒绝 \(key)")
        }
    }

    @Test func rpmKeyMapsFanIndexAndRejectsOutOfRange() {
        #expect(FanHelperKeys.rpmKey(fan: 0) == "F0Md")
        #expect(FanHelperKeys.rpmKey(fan: 7) == "F7Md")
        #expect(FanHelperKeys.rpmKey(fan: 8) == nil)
        #expect(FanHelperKeys.rpmKey(fan: -1) == nil)
        #expect(FanHelperKeys.modeKey == "FS!")
        #expect(FanHelperKeys.systemAutoMode == 0x01)
        #expect(FanHelperKeys.forcedManualMode == 0x02)
    }
}

// MARK: - 真二进制协议契约

@Suite struct T222FanHelperBinaryTests {

    @Test func pingRoundTripsOK() throws {
        let result = try runRealHelper(#"{"action":"ping"}"#)
        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"ok":true}"#)
        #expect(result.stderr.isEmpty, "ping 不该有诊断输出")
    }

    @Test func rejectsNonWhitelistedKeysWithExitOne() throws {
        // 温度读键与充电域键（红线二本体）各一发：都必须 exit 1 + stderr 明示拒绝
        for key in ["TC0P", "BC1C"] {
            let line = #"{"action":"set","key":"\#(key)","value":50}"#
            let result = try runRealHelper(line)
            #expect(result.status == 1, "\(key) 应被 exit 1 拒绝")
            #expect(result.stderr.contains("拒绝"), "stderr 应写拒绝原因: \(result.stderr)")
            #expect(result.stdout.contains(#""ok":false"#), "stdout 应先补一条失败应答")
        }
    }

    @Test func malformedLinesAreAnsweredAndLoopSurvivesUntilEOF() throws {
        // 一进程多发：坏 JSON → 应答 ok:false 不死；未知 action → 应答 ok:false；
        // 随后 ping 仍通（循环未断）；EOF 正常 exit 0
        let input = [
            "这不是 JSON",
            #"{"action":"dance"}"#,
            #"{"action":"ping"}"#,
            #"{"noAction":true}"#,
        ].joined(separator: "\n")
        let result = try runRealHelper(input)
        #expect(result.status == 0, "EOF 前不许死：实得 exit \(result.status)")
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].contains(#""ok":false"#))
        #expect(lines[1].contains(#""ok":false"#))
        #expect(lines[2] == #"{"ok":true}"#)
        #expect(lines[3].contains(#""ok":false"#))
    }

    @Test func sourcePinsInstallProtocolAndWhitelistBasis() throws {
        // 安装协议与红线依据以源码锚点钉死：改坏即失效的文件名/机制名
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Support/FanHelper/main.swift"),
            encoding: .utf8
        )
        for anchor in [
            "SMAppService",
            "com.statusbutler.fanhelper.plist",
            "LaunchDaemons",
            "红线二",
            "白名单",
        ] {
            #expect(source.contains(anchor), "main.swift 缺锚点: \(anchor)")
        }
        // plist 模板必须在位（安装协议交付物）
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Support/FanHelper/com.statusbutler.fanhelper.plist")
        #expect(FileManager.default.fileExists(atPath: plist.path))
        let plistText = try String(contentsOf: plist, encoding: .utf8)
        #expect(plistText.contains("com.statusbutler.fanhelper"))
        #expect(plistText.contains("SMAppService"))
    }
}

// MARK: - FanHelperClient（假 helper 全链路）

private enum FakeFanHelperScript {
    /// 造一个假 helper：逐行回固定应答，并把收到的请求行落盘供断言。
    /// echoOk=false 时回 {"ok":false,"error":"nope"}（驱动失败路径）。
    static func make(echoOK: Bool) throws -> (path: String, requestsFile: String) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "fanhelper-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "fake-helper")
        let requestsFile = directory.appending(path: "requests.log").path
        let response = echoOK ? #"{"ok":true}"# : #"{"ok":false,"error":"nope"}"#
        // bash 3.2 兼容（无 mapfile）：read 一行转发一行；printf 不带换行的变量
        // 引用全用 ${var} 定界（AGENTS：中文粘变量名坑——本脚本纯 ASCII 亦守纪律）
        let body = """
        #!/bin/bash
        while IFS= read -r line; do
            printf '%s\\n' "${line}" >> '\(requestsFile)'
            printf '%s\\n' '\(response)'
        done
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: script.path)
        return (script.path, requestsFile)
    }
}

@Suite struct T222FanHelperClientTests {

    @Test func clientSpeaksJSONLineProtocolWithFakeHelper() async throws {
        let fake = try FakeFanHelperScript.make(echoOK: true)
        let client = FanHelperClient(helperPath: fake.path)
        #expect(client.isInstalled)

        #expect(await client.setMode(0x02))
        #expect(await client.setRPM(4000, fan: 0))
        #expect(await client.restoreSystem())

        // 客户端发射的请求行：解析成 JSON 对字段（JSONSerialization 键序不稳定）
        let log = try String(contentsOfFile: fake.requestsFile, encoding: .utf8)
        let requests = log.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        #expect(requests.count == 3)
        #expect(requests[0]["action"] as? String == "set")
        #expect(requests[0]["key"] as? String == "FS!")
        #expect(requests[0]["value"] as? Int == 2)
        #expect(requests[1]["key"] as? String == "F0Md")
        #expect(requests[1]["value"] as? Int == 4000)
        #expect(requests[2]["key"] as? String == "FS!")
        #expect(requests[2]["value"] as? Int == 1)  // restoreSystem = 交还系统自动
    }

    @Test func clientRejectsNonWhitelistedKeysLocally() async throws {
        let fake = try FakeFanHelperScript.make(echoOK: true)
        let client = FanHelperClient(helperPath: fake.path)
        // 红线二客户端闸：非风扇域键在拉起子进程前就地拒绝
        #expect(!(await client.write(key: "TC0P", value: 50)))
        #expect(!(await client.write(key: "BC1C", value: 80)))
        #expect(!(await client.setRPM(3000, fan: 9)))  // 越界序号构不出合法键
        // 未经请求的假 helper 不该收到任何行
        #expect(!FileManager.default.fileExists(atPath: fake.requestsFile))
    }

    @Test func missingHelperDegradesToFalse() async {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "fanhelper-not-here-\(UUID().uuidString)")
        let client = FanHelperClient(helperPath: missing.path)
        #expect(!client.isInstalled)
        #expect(!(await client.ping()))
        #expect(!(await client.setMode(0x02)))
        #expect(!(await client.setRPM(4000, fan: 0)))
        #expect(!(await client.restoreSystem()))
    }

    @Test func failingResponsesAndBadPayloadsFoldToFalse() async throws {
        let failing = try FakeFanHelperScript.make(echoOK: false)
        let client = FanHelperClient(helperPath: failing.path)
        #expect(!(await client.setMode(0x02)), "ok:false 应答必须折叠为 false")
        // 应答解析的纯函数面：ok:true / ok:false / 坏 JSON / 空行
        #expect(FanHelperClient.responseIsOK(#"{"ok":true}"#))
        #expect(!FanHelperClient.responseIsOK(#"{"ok":false,"error":"x"}"#))
        #expect(!FanHelperClient.responseIsOK("not json"))
        #expect(!FanHelperClient.responseIsOK(""))
        #expect(!FanHelperClient.responseIsOK(#"{"ok":"yes"}"#))  // 类型不符不算 true
    }
}
