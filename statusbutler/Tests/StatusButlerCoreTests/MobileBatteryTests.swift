import Foundation
import Testing
@testable import StatusButlerCore

// T-053 iDevice 电量 Helper 代码半场：manifest 锁定契约、构建脚本 dry-run/--help/参数白名单
// （子进程真实执行，非源码文本匹配）、helper 输出解析纯函数（多设备/Watch 无电量/坏行/
// 类型防御/去重/空输出）、helper 缺失→unavailable、JSON 往返与面板旁路汇总。
// 真跑构建与真机 USB 冒烟留 T-053b——本套件零网络零硬件依赖。

@Suite struct MobileBatteryTests {

    // MARK: - 依赖清单（manifest）

    private struct ManifestDependency: Decodable {
        let name: String
        let repository: String
        let version: String
        let tag: String
        let commit: String
        let license: String
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let minimumMacOS: String
        let sourceBuildOrder: [String]
        let dependencies: [ManifestDependency]
    }

    /// #filePath 回溯包根：Tests/StatusButlerCoreTests → Tests → 包根
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadManifest() throws -> Manifest {
        let url = packageRoot().appending(path: "Support/mobile-battery-dependencies.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    @Test func manifestPinsAllSixLibrariesInBuildOrder() throws {
        let manifest = try loadManifest()
        // 六库齐备且构建顺序正确：openssl 打底（autotools 链依赖它）→ plist → glue →
        // usbmuxd → tatsu → libimobiledevice 收口（依赖前五个的全部产物）
        #expect(manifest.sourceBuildOrder == [
            "openssl", "libplist", "libimobiledevice-glue", "libusbmuxd", "libtatsu", "libimobiledevice",
        ])
        #expect(manifest.dependencies.count == 6)
        #expect(Set(manifest.dependencies.map(\.name)) == Set(manifest.sourceBuildOrder))
        #expect(manifest.minimumMacOS == "13.0") // 与 Package.swift 平台下限一致
        // tag+commit 双锁：版本可读性归 tag，供应链钉死归 commit
        for dependency in manifest.dependencies {
            #expect(!dependency.tag.isEmpty)
            #expect(!dependency.version.isEmpty)
            #expect(dependency.repository.hasPrefix("https://github.com/"))
            #expect(!dependency.license.isEmpty)
        }
    }

    @Test func manifestCommitsAreFortyHexCharacters() throws {
        let manifest = try loadManifest()
        // 40 位小写十六进制 = git SHA-1 全长；短哈希/大写/非十六进制都会击穿脚本的锁定校验
        let hex = /[0-9a-f]{40}/
        for dependency in manifest.dependencies {
            #expect(dependency.commit.wholeMatch(of: hex) != nil, "\(dependency.name) commit 形态不合法: \(dependency.commit)")
        }
    }

    // MARK: - 构建脚本契约（子进程真实执行）

    private struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runScript(_ arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [packageRoot().appending(path: "scripts/build-mobile-battery-helper.sh").path] + arguments
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

    @Test func scriptDryRunPrintsPlanWithAllSixLibraries() throws {
        let result = try runScript(["--dry-run"])
        #expect(result.status == 0)
        for name in ["openssl", "libplist", "libimobiledevice-glue", "libusbmuxd", "libtatsu", "libimobiledevice"] {
            #expect(result.stdout.contains(name), "dry-run 计划缺 \(name)")
        }
        // 计划必须带锁：manifest 的 commit（供应链可见性）与产物路径（消费方契约）
        #expect(result.stdout.contains("commit=45e844fa2a14ec92d146bd8f5778ac130b6625fb"))
        #expect(result.stdout.contains("commit=149f7623c672c1fa73122c7119a12bfc0012f2ac"))
        #expect(result.stdout.contains("statusbutler-mobilebattery"))
        // dry-run 零副作用：不创建工作目录（真跑才允许落盘）
        #expect(!FileManager.default.fileExists(atPath: packageRoot().appending(path: ".build/mobile-battery/dependencies.json").path))
    }

    @Test func scriptHelpExitsZeroWithoutToolchain() throws {
        let result = try runScript(["--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("用法"))
        #expect(result.stdout.contains("--dry-run"))
    }

    @Test func scriptRejectsUnknownAndPositionalArguments() throws {
        // 白名单校验先于一切文件/git/编译动作（Mimosa 防注入纪律）：
        // 未知旗标与裸位置参数都 exit 2，不产生任何副作用
        let bogus = try runScript(["--bogus"])
        #expect(bogus.status == 2)
        #expect(bogus.stderr.contains("未知参数"))
        let positional = try runScript(["/tmp/evil;rm-rf"])
        #expect(positional.status == 2)
        #expect(positional.stderr.contains("未知参数"))
        // 混在合法参数后的未知参数同样拦下
        let mixed = try runScript(["--dry-run", "--make-coffee"])
        #expect(mixed.status == 2)
    }

    // MARK: - helper 输出解析（纯函数）

    @Test func parseReadsMultiDeviceJSONLines() {
        let stdout = """
        {"name":"Lin 的 iPhone","udid":"00008101-ABCD","kind":"iPhone","batteryPercent":72,"charging":true}
        {"name":"iPad mini","udid":"00008120-1234","kind":"iPad","batteryPercent":45,"charging":false}
        """
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices.count == 2)
        #expect(devices[0] == MobileBatteryDevice(
            name: "Lin 的 iPhone", udid: "00008101-ABCD", kind: .iPhone, batteryPercent: 72, charging: true
        ))
        #expect(devices[1] == MobileBatteryDevice(
            name: "iPad mini", udid: "00008120-1234", kind: .iPad, batteryPercent: 45, charging: false
        ))
    }

    @Test func parseWatchLineWithoutBatteryKeepsDeviceWithNilReadings() {
        // Watch 经 companion_proxy 读电量常失败：设备必须在列，读数如实为 nil
        let stdout = #"{"name":"Apple Watch","udid":"w-0001","kind":"Watch"}"#
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices == [MobileBatteryDevice(
            name: "Apple Watch", udid: "w-0001", kind: .watch, batteryPercent: nil, charging: nil
        )])
    }

    @Test func parseSkipsMalformedLinesWithoutPoisoningGoodOnes() {
        let stdout = """
        不是 JSON
        {"name":"无 udid","kind":"iPhone","batteryPercent":50}
        {"name":"iPod 上市了吗","udid":"u2","kind":"iPod"}
        [1,2,3]
        "孤零零的字符串"
        {"name":"空白键","udid":"   ","kind":"iPad"}
        {"name":"守规矩","udid":"u3","kind":"iPad","batteryPercent":33}
        """
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices.map(\.udid) == ["u3"])
        #expect(devices[0].batteryPercent == 33)
    }

    @Test func parseDefendsAgainstSurprisingFieldTypes() {
        let stdout = """
        {"name":"A","udid":"a","kind":"iPhone","batteryPercent":"88%","charging":"YES"}
        {"name":"B","udid":"b","kind":"iPhone","batteryPercent":72.4,"charging":1}
        {"name":"C","udid":"c","kind":"iPhone","batteryPercent":true,"charging":"maybe"}
        {"name":"D","udid":"d","kind":"iPhone","batteryPercent":150,"charging":2}
        """
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices.count == 4)
        // A：字符串 "88%" 与 "YES" 都能收（C 侧 plist 值域漂移的常态）
        #expect(devices[0].batteryPercent == 88)
        #expect(devices[0].charging == true)
        // B：plist REAL 小数四舍五入；数值 1 认作充电中
        #expect(devices[1].batteryPercent == 72)
        #expect(devices[1].charging == true)
        // C：布尔当电量=没读到；不认识的字符串=没读到
        #expect(devices[2].batteryPercent == nil)
        #expect(devices[2].charging == nil)
        // D：越界电量不截断编造；2 不是合法充电态
        #expect(devices[3].batteryPercent == nil)
        #expect(devices[3].charging == nil)
    }

    @Test func parseEmptyOrWhitespaceOutputYieldsNoDevices() {
        // helper 正常路径之一就是"没有 iDevice"：空输出、空白行、空行混排都返回空表
        #expect(MobileBatteryHelperReader.parse(stdout: "").isEmpty)
        #expect(MobileBatteryHelperReader.parse(stdout: "\n \n\t\n").isEmpty)
    }

    @Test func parseDeduplicatesByUDIDKeepingFirstLine() {
        // 同一设备 USB/网络双通道重复上报：按 udid 去重，首行（脚本按构建序枚举的通道）胜出
        let stdout = """
        {"name":"iPhone（USB）","udid":"dup-1","kind":"iPhone","batteryPercent":72,"charging":true}
        {"name":"iPhone（网络）","udid":"dup-1","kind":"iPhone","batteryPercent":80,"charging":false}
        {"name":"独一份","udid":"solo-1","kind":"iPad","batteryPercent":10}
        """
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices.count == 2)
        #expect(devices[0].name == "iPhone（USB）")
        #expect(devices[0].batteryPercent == 72)
        #expect(devices[1].udid == "solo-1")
    }

    @Test func parseFallsBackToKindNameWhenNameMissing() {
        // 名字读不到但 udid/kind 齐全：退到 kind 名保住设备可见性，"未命名"文案归展示层
        let stdout = #"{"udid":"u9","kind":"Watch","batteryPercent":66}"#
        let devices = MobileBatteryHelperReader.parse(stdout: stdout)
        #expect(devices == [MobileBatteryDevice(name: "Watch", udid: "u9", kind: .watch, batteryPercent: 66)])
    }

    // MARK: - 读取器（注入执行器）

    @Test func readerMissingHelperPathFoldsToUnavailable() async {
        // helper 未构建是常态而非异常：默认执行器对缺失路径收敛为 unavailable + 空数组
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "statusbutler-mobilebattery-\(UUID().uuidString)")
        let reading = await MobileBatteryHelperReader(helperPath: missing.path).read()
        #expect(reading.status == .unavailable)
        #expect(reading.devices.isEmpty)
        #expect(reading == .unavailable)
    }

    @Test func readerParsesInjectedExecutorOutput() async {
        let fixture = """
        {"name":"iPhone","udid":"u1","kind":"iPhone","batteryPercent":72,"charging":true}
        {"name":"Watch","udid":"w1","kind":"Watch"}
        """
        let reader = MobileBatteryHelperReader(helperPath: "/fake/helper") { path in
            #expect(path == "/fake/helper")
            return fixture
        }
        let reading = await reader.read()
        #expect(reading.status == .available)
        #expect(reading.devices.count == 2)
        #expect(reading.devices[1].batteryPercent == nil)
    }

    @Test func readerExecutorFailureFoldsToUnavailable() async {
        // helper 在但执行失败（崩溃/非零退出码）：同样收敛为 unavailable，监控路径不抛错
        struct Boom: Error {}
        let reader = MobileBatteryHelperReader(helperPath: "/fake/helper") { _ in throw Boom() }
        let reading = await reader.read()
        #expect(reading == .unavailable)
    }

    // MARK: - JSON 往返与面板旁路汇总

    @Test func deviceJSONRoundTripPreservesAllFields() throws {
        // 与 helper 契约同名同型：编码再解码必须无损（含 nil 读数的 Watch 形态）
        let devices = [
            MobileBatteryDevice(name: "Lin 的 iPhone", udid: "u1", kind: .iPhone, batteryPercent: 72, charging: true),
            MobileBatteryDevice(name: "Watch", udid: "w1", kind: .watch, batteryPercent: nil, charging: nil),
            MobileBatteryDevice(name: "iPad", udid: "p1", kind: .iPad, batteryPercent: 0, charging: false),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for device in devices {
            let decoded = try decoder.decode(MobileBatteryDevice.self, from: encoder.encode(device))
            #expect(decoded == device)
        }
        // 单行 wire 形态：kind 用契约字符串、缺省字段不出现也不影响解码
        let wire = #"{"name":"iPhone","udid":"u2","kind":"iPhone","batteryPercent":50,"charging":false}"#
        #expect(try decoder.decode(MobileBatteryDevice.self, from: Data(wire.utf8))
            == MobileBatteryDevice(name: "iPhone", udid: "u2", kind: .iPhone, batteryPercent: 50, charging: false))
    }

    @Test func summaryFoldsReadingAndCountsDevices() {
        // 面板旁路桥：available 折叠成设备清单；unavailable 折叠成空汇总（走引导文案分支）
        let devices = [
            MobileBatteryDevice(name: "iPhone", udid: "u1", kind: .iPhone, batteryPercent: 72, charging: true),
            MobileBatteryDevice(name: "Watch", udid: "w1", kind: .watch),
        ]
        let summary = MobileBatterySummary(reading: MobileBatteryReading(status: .available, devices: devices))
        #expect(summary.total == 2)
        #expect(summary.devices == devices)
        let unavailable = MobileBatterySummary(reading: .unavailable)
        #expect(unavailable.total == 0)
        #expect(unavailable == .empty)
        // total 与 devices.count 恒等（计算属性单一真相）
        #expect(MobileBatterySummary(devices: []).total == 0)
    }
}
