import Foundation
import Testing
@testable import StatusButlerCore

// A14-ε（E9 · AU-02）：AppIntent 执行注入路由。intent 是框架反射构造的值类型，
// 断言点在"注册的执行器收到了哪个 ButlerCommand"（动词/参数即动作真值表的寻址键）。
// .serialized：SharedIntentExecutor.shared 是进程级单例，串行避免注册态跨用例串味
// （每条用例开头先 reset 再注册自己的探针）。
@Suite(.serialized) struct ButlerIntentsTests {

    /// 探针执行器：记录收到的命令并返回 performed。锁保护可变数组——
    /// 调用发生在 SharedIntentExecutor actor 内（非主线程），@unchecked Sendable 是
    /// 对"全部访问都经锁"的手工背书
    final class ExecutorProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [ButlerCommand] = []

        var commands: [ButlerCommand] {
            lock.lock(); defer { lock.unlock() }
            return _commands
        }

        func makeExecutor() -> @Sendable (ButlerCommand) -> ActionOutcome {
            { [self] command in
                lock.lock(); defer { lock.unlock() }
                _commands.append(command)
                return .performed
            }
        }
    }

    private func registerProbe() async -> ExecutorProbe {
        let probe = ExecutorProbe()
        await SharedIntentExecutor.shared.resetForTesting()
        await SharedIntentExecutor.shared.register(probe.makeExecutor())
        return probe
    }

    // MARK: - 三个无参 Intent 的路由

    @Test func volumeUpIntentRoutesVolumeUpVerb() async throws {
        let probe = await registerProbe()
        _ = try await VolumeUpIntent().perform()
        #expect(probe.commands.map(\.verb) == ["volume/up"])
        #expect(probe.commands.first?.args.isEmpty == true)
    }

    @Test func volumeMuteIntentRoutesMuteVerb() async throws {
        let probe = await registerProbe()
        _ = try await VolumeMuteIntent().perform()
        #expect(probe.commands.map(\.verb) == ["volume/mute"])
    }

    @Test func showPanelIntentRoutesPanelShowVerb() async throws {
        let probe = await registerProbe()
        _ = try await ShowPanelIntent().perform()
        #expect(probe.commands.map(\.verb) == ["panel/show"])
    }

    // MARK: - 参数化 volume/set 档位映射

    @Test func volumeSetIntentMapsStepToValueArg() async throws {
        let probe = await registerProbe()
        _ = try await VolumeSetIntent(level: .fifty).perform()
        #expect(probe.commands.map(\.verb) == ["volume/set"])
        #expect(probe.commands.first?.args["value"] == "50")

        _ = try await VolumeSetIntent(level: .off).perform()
        #expect(probe.commands.last?.args["value"] == "0")

        _ = try await VolumeSetIntent(level: .hundred).perform()
        #expect(probe.commands.last?.args["value"] == "100")
    }

    @Test func volumeSetCommandStaysInsideWhitelist() {
        // 直构的档位命令必须过 resolve 白名单（AC-05 同源校验，纵深防御）
        for step in [VolumeStep.off, .fifty, .hundred] {
            let command = ButlerCommand(verb: "volume/set", args: ["value": String(step.rawValue)])
            #expect(ButlerCommand.resolve(command) == .forwardedToApp(actionID: "volume"))
        }
    }

    @Test func volumeStepRawValuesAreTenStepGears() {
        let expected = Array(stride(from: 0, through: 100, by: 10))
        #expect(VolumeStep.allCases.map(\.rawValue) == expected)  // 档位表即合法值域
    }

    // MARK: - 未注册诚实拒绝

    @Test func unregisteredExecutorRejectsWithoutPretending() async {
        await SharedIntentExecutor.shared.resetForTesting()
        let outcome = await SharedIntentExecutor.shared.perform(ButlerCommand(verb: "volume/up"))
        guard case .rejected(let reason) = outcome else {
            Issue.record("未注册应 rejected，得到 \(outcome)")
            return
        }
        #expect(reason.contains("未注册"))
        // 收尾恢复未注册态，避免影响后续用例
        await SharedIntentExecutor.shared.resetForTesting()
    }
}
