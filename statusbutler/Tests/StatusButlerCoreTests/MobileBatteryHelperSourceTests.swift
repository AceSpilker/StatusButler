import Foundation
import Testing

@testable import StatusButlerCore

// A14-δ iDevice helper C 源契约：main.m 的取数路线锚点钉死、fixture 输出样例与
// HelperReader 解析对拍、构建脚本 dry-run 必须含编译段。真跑构建与真机 USB 冒烟
// 仍归 T-053b——本套件零网络零硬件依赖（与 MobileBatteryTests 同纪律）。
@Suite struct MobileBatteryHelperSourceTests {

    // #filePath 回溯包根：Tests/StatusButlerCoreTests → Tests → 包根
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var helperDirectory: URL {
        packageRoot().appending(path: "Support/MobileBatteryHelper")
    }

    // MARK: - C 源契约锚点

    @Test func helperMainSourcePinsLibimobiledeviceRoute() throws {
        // C 源以文本锚点钉死路线：usbmuxd 枚举 → idevice → lockdownd 握手 → 电量域。
        // 锚点选"改坏即失效"的 API 名与域/键名，不做风格匹配
        let source = try String(
            contentsOf: helperDirectory.appending(path: "main.m"),
            encoding: .utf8
        )
        for anchor in [
            "usbmuxd_get_device_list",
            "idevice_new_with_options",
            "lockdownd_client_new_with_handshake",
            "lockdownd_get_value",
            "com.apple.mobile.battery",
            "BatteryCurrentCapacity",
            "BatteryIsCharging",
            "DeviceClass",
        ] {
            #expect(source.contains(anchor), "main.m 缺路线锚点: \(anchor)")
        }
        // 契约三 kind 必须在发射面里（否则 Swift 侧整行丢弃）
        for kind in ["iPhone", "iPad", "Watch"] {
            #expect(source.contains("\"\(kind)\""), "main.m 缺契约 kind 字面量: \(kind)")
        }
        // 短命单发进程铁律：契约只属于 stdout，诊断走 stderr
        #expect(source.contains("fprintf(stderr"))
    }

    // MARK: - fixture 输出样例与 HelperReader 对拍

    @Test func fixtureOutputParsesThroughHelperReader() throws {
        // fixture 是 main.m 输出形态的样例文件：HelperReader.parse 必须逐行吃下，
        // 含"Watch 无电量"行——C 源与 Swift 解析器对同一契约的对拍
        let fixture = try String(
            contentsOf: helperDirectory.appending(path: "fixture-output.jsonl"),
            encoding: .utf8
        )
        let devices = MobileBatteryHelperReader.parse(stdout: fixture)
        #expect(devices.count == 3)
        #expect(devices[0] == MobileBatteryDevice(
            name: "Lin 的 iPhone", udid: "00008101-000A2C9D1E2F",
            kind: .iPhone, batteryPercent: 72, charging: true
        ))
        #expect(devices[1] == MobileBatteryDevice(
            name: "iPad mini", udid: "00008120-112233445566",
            kind: .iPad, batteryPercent: 45, charging: false
        ))
        #expect(devices[2] == MobileBatteryDevice(
            name: "Apple Watch", udid: "00000000-000000000001",
            kind: .watch, batteryPercent: nil, charging: nil
        ))
    }

    @Test func fixtureLineFieldNamesMatchContractExactly() throws {
        // 字段名一字不差（HelperReader.swift 契约）：fixture 逐行核对硬字段，
        // C 侧改字段名必须同时改 fixture + Swift 契约，三处一致
        let fixture = try String(
            contentsOf: helperDirectory.appending(path: "fixture-output.jsonl"),
            encoding: .utf8
        )
        let lines = fixture.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.count == 3)
        for line in lines {
            for field in ["\"name\":", "\"udid\":", "\"kind\":"] {
                #expect(line.contains(field), "fixture 行缺契约字段: \(field) → \(line)")
            }
        }
    }

    // MARK: - 构建脚本 dry-run 含编译段（子进程真实执行）

    private struct ScriptResult {
        let status: Int32
        let stdout: String
    }

    @Test func scriptDryRunIncludesHelperCompileStage() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            packageRoot().appending(path: "scripts/build-mobile-battery-helper.sh").path,
            "--dry-run",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        // 先读完管道再 wait：缓冲区满时 wait 会死锁（与其他脚本契约用例同纪律）
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = ScriptResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self)
        )
        #expect(result.status == 0)
        // C 源已交付：dry-run 必须报告源码就绪并展示编译段（clang + 六库链接）
        #expect(result.stdout.contains("main.m（就绪）"))
        #expect(result.stdout.contains("编译段"))
        #expect(result.stdout.contains("clang"))
        #expect(result.stdout.contains("libimobiledevice-1.0"))
    }
}
