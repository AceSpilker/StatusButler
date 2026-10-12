import Foundation
import Testing

// T-003: 红线守卫 —— 扫描源码禁止出现越权 API 模式（A2·S12 红线的可执行化）
// 风扇域 SMC 写（FS! / F0Md）属于 E11 白名单例外，将来只能在 Thermal 模块内出现
@Suite struct ForbiddenPatternGuardTests {
    private static let forbidden: [(pattern: String, reason: String)] = [
        ("SecKeychainSearch", "红线一：不碰钥匙串"),
        ("kIOPMSchedulePowerEvent", "红线二：不写电源域 SMC"),
        ("kIOPMChargeToFull", "红线二：不越权控制充电"),
        (" NSTask(", "最小攻击面：不直接起任意进程"),
    ]

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/StatusButlerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 包根
            .appending(path: "Sources")
    }

    @Test func sourcesContainNoForbiddenPatterns() throws {
        let root = sourcesRoot()
        var violations: [String] = []
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        for file in files where !file.path.contains("Thermal") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for rule in Self.forbidden where text.contains(rule.pattern) {
                violations.append("\(file.lastPathComponent): \(rule.reason)")
            }
        }
        if !violations.isEmpty {
            print("发现越权模式：\n" + violations.joined(separator: "\n"))
        }
        #expect(violations.isEmpty)
    }
}
