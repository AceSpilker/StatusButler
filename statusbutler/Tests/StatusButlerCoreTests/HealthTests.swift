import Foundation
import Testing
@testable import StatusButlerCore

// T-042: 体检判定纯函数（On/Off/未知→notApplicable）+ 得分计算（notApplicable 不计分）+ 假检查器编排
@Suite struct HealthTests {
    private func result(_ status: HealthStatus, id: String = "") -> HealthCheckResult {
        HealthCheckResult(id: id, title: id, status: status, detail: "", remediationHint: "")
    }

    @Test func fileVaultEvaluateOnOffUnknown() {
        #expect(FileVaultCheck.evaluate(stdout: "FileVault is On.\n").status == .pass)
        #expect(FileVaultCheck.evaluate(stdout: "FileVault is Off.\n").status == .fail)
        #expect(FileVaultCheck.evaluate(stdout: "unexpected output").status == .notApplicable)
        #expect(FileVaultCheck.evaluate(stdout: "").status == .notApplicable)
        #expect(!FileVaultCheck.evaluate(stdout: "FileVault is Off.\n").remediationHint.isEmpty)
    }

    @Test func gatekeeperEvaluateEnabledDisabledUnknown() {
        #expect(GatekeeperCheck.evaluate(stdout: "assessments enabled\n").status == .pass)
        #expect(GatekeeperCheck.evaluate(stdout: "assessments disabled\n").status == .fail)
        #expect(GatekeeperCheck.evaluate(stdout: "garbage").status == .notApplicable)
        #expect(GatekeeperCheck.evaluate(stdout: "").status == .notApplicable)
    }

    @Test func firewallEvaluateEnabledDisabledUnknown() {
        #expect(FirewallCheck.evaluate(stdout: "Firewall is enabled. (State = 1)\n").status == .pass)
        #expect(FirewallCheck.evaluate(stdout: "Firewall is disabled. (State = 0)\n").status == .warn)
        #expect(FirewallCheck.evaluate(stdout: "unrecognized").status == .notApplicable)
        #expect(FirewallCheck.evaluate(stdout: "").status == .notApplicable)
    }

    @Test func softwareUpdateEvaluateMatchingStaleMissing() {
        #expect(SoftwareUpdateCheck.evaluate(attemptedOutput: "15.1 (24B83)\n", currentBuild: "24B83").status == .pass)
        let stale = SoftwareUpdateCheck.evaluate(attemptedOutput: "15.2 (24C101)\n", currentBuild: "24B83")
        #expect(stale.status == .warn)   // 仅提示级，绝不 fail
        #expect(!stale.remediationHint.isEmpty)
        #expect(SoftwareUpdateCheck.evaluate(attemptedOutput: nil, currentBuild: "24B83").status == .notApplicable)
        #expect(SoftwareUpdateCheck.evaluate(attemptedOutput: "", currentBuild: "24B83").status == .notApplicable)
        #expect(SoftwareUpdateCheck.evaluate(attemptedOutput: "no parens here", currentBuild: "24B83").status == .notApplicable)
    }

    @Test func liveCheckUsesInjectedCollector() throws {
        // 注入假命令输出：不触系统即可验证 live 检查的 run→evaluate 全链路
        let healthy = FileVaultCheck(collect: { "FileVault is On." })
        #expect(healthy.run().status == .pass)
        let sick = GatekeeperCheck(collect: { "assessments disabled" })
        #expect(sick.run().status == .fail)
        // 命令执行失败 → 无法判定，不误报
        let broken = FirewallCheck(collect: { throw HealthCheckError.commandFailed(exitCode: 1) })
        #expect(broken.run().status == .notApplicable)
        let noRecord = SoftwareUpdateCheck(attempted: { throw HealthCheckError.commandFailed(exitCode: 1) },
                                           currentBuild: { "24B83" })
        #expect(noRecord.run().status == .notApplicable)
    }

    @Test func scoreExcludesNotApplicable() {
        #expect(HealthReport(results: [result(.pass), result(.notApplicable)]).score == 100)
        #expect(HealthReport(results: [result(.pass), result(.warn), result(.fail)]).score == 33)
        #expect(HealthReport(results: [result(.pass), result(.pass), result(.fail)]).score == 67)
        #expect(HealthReport(results: [result(.notApplicable), result(.notApplicable)]).score == 100)
        #expect(HealthReport(results: []).score == 100)
        #expect(HealthReport(results: [result(.fail)]).score == 0)
    }

    @Test func auditorRunsAllAndKeepsRegistrationOrder() async {
        struct FakeCheck: HealthChecking {
            let id: String
            let status: HealthStatus
            func run() -> HealthCheckResult {
                HealthCheckResult(id: id, title: id, status: status, detail: "", remediationHint: "")
            }
        }
        let report = await HealthAuditor(checks: [
            FakeCheck(id: "a", status: .pass),
            FakeCheck(id: "b", status: .warn),
            FakeCheck(id: "c", status: .fail),
            FakeCheck(id: "d", status: .notApplicable),
        ]).runAll()
        #expect(report.results.map(\.id) == ["a", "b", "c", "d"])
        #expect(report.results.map(\.status) == [.pass, .warn, .fail, .notApplicable])
        #expect(report.score == 33)
        // 空检查组：报告为空、满分（无可检项 ≠ 不健康）
        let empty = await HealthAuditor(checks: []).runAll()
        #expect(empty.results.isEmpty)
        #expect(empty.score == 100)
    }

    @Test func warnAndFailAlwaysCarryRemediationHint() {
        // 修补指引契约：所有 fail/warn 判定必须带非空"怎么修"，否则面板"去修复"无从谈起
        let cases = [
            FileVaultCheck.evaluate(stdout: "FileVault is Off."),
            GatekeeperCheck.evaluate(stdout: "assessments disabled"),
            FirewallCheck.evaluate(stdout: "Firewall is disabled. (State = 0)"),
            SoftwareUpdateCheck.evaluate(attemptedOutput: "15.2 (24C101)", currentBuild: "24B83"),
        ]
        for item in cases {
            #expect(!item.remediationHint.isEmpty)
        }
    }
}
