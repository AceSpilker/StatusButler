import Testing
import Foundation
@testable import StatusButlerCore

// T-052: 自动化引擎（butler:// URL 路由器 + statusbutler CLI 引擎 + 执行器绑定构建器）
// （A9·AU-01/03/04、AC-02/05）。纪律：零系统调用——执行器/快照读取/宽接口全部注入假实现；
// 退出码规约表与白名单同源性（AC-05）在此钉死，防止薄壳与注册表两处漂移。

// 锁保护以满足 @Sendable 执行器闭包的捕获（Swift Testing 用例并行，同 T-034 测试基建）
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ item: String) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// 快照样本：全域有值（nil 分支与不可用分支另测），断言锚定人类可读行
private func makeSnapshot() -> WidgetSnapshot {
    WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_760_000_000),
        battery: .battery(level: 85, charging: true),
        link: .wifi(ssid: "Home-5G", signalBars: 4),
        volume: VolumeState(level: 50, isMuted: false),
        maxCelsius: 45.3,
        fanAverageRPM: 2400,
        netBytesPerSec: .init(in: 1_234_567, out: 89_012)
    )
}

// MARK: - URL 路由器（AU-01 三态）

@Suite struct ButlerURLRouterTests {
    @Test func routesEveryWhitelistedVerbToExecutor() {
        let recorder = Recorder()
        let center = ActionCenter(executor: { action, command in
            recorder.record("\(action.id)|\(command.verb)")
            return .performed
        })
        let router = ButlerURLRouter()
        let cases: [(url: String, actionID: String)] = [
            ("butler://volume/up", "volume"), ("butler://volume/down", "volume"),
            ("butler://volume/set?value=50", "volume"), ("butler://volume/mute", "mute"),
            ("butler://panel/show", "panel"), ("butler://panel/thermal", "panel"),
            ("butler://panel/battery", "panel"), ("butler://panel/network", "panel"),
            ("butler://bluetooth/connect?device=AirPods", "bluetooth-connect"),
            ("butler://fan/auto", "fan-max"), ("butler://fan/max", "fan-max"),
            ("butler://fan/rpm?value=4000", "fan-max"),
            ("butler://slot/cycle", "slot-cycle"),
            ("butler://theme/apply?name=minimal", "theme"),
            ("butler://screen/off", "screen-off"),
            ("butler://status", "status"),
        ]
        for c in cases {
            #expect(router.handle(url: URL(string: c.url)!, executor: center) == .handled(.performed), "路由 \(c.url)")
        }
        // 全部白名单动词都进了执行器（AC-05：一个不落）
        #expect(recorder.snapshot.count == cases.count)
        #expect(Set(recorder.snapshot.map { $0.split(separator: "|").first.map(String.init) ?? "" })
            == Set(cases.map(\.actionID)))
    }

    @Test func foreignSchemesAreNotOursAndNeverTouchExecutor() {
        let recorder = Recorder()
        let center = ActionCenter(executor: { action, _ in
            recorder.record(action.id)
            return .performed
        })
        let router = ButlerURLRouter()
        // 非 butler scheme 一律 notOurs（含 butler-debug 前缀混淆）；调用方据此交还系统
        for s in ["https://example.com/volume/up", "mailto:x@y.z", "file:///volume/up",
                  "shortcuts://run?name=x", "butler-debug://volume/up"] {
            #expect(router.handle(url: URL(string: s)!, executor: center) == .notOurs, "应交还系统：\(s)")
        }
        #expect(recorder.snapshot.isEmpty)
    }

    @Test func unknownVerbsCarryStructuredCommandError() {
        // .rejected 必须携带结构化 CommandError（AU-01 静默日志与 CLI 退出码 1 的分流依据）
        let center = ActionCenter(executor: { _, _ in .performed })
        let router = ButlerURLRouter()
        #expect(router.handle(url: URL(string: "butler://rm/rf")!, executor: center)
            == .rejected(.unknownCommand("rm/rf")))
        #expect(router.handle(url: URL(string: "butler://volume")!, executor: center)
            == .rejected(.unknownCommand("volume")))  // 缺限定词
        #expect(router.handle(url: URL(string: "butler://")!, executor: center)
            == .rejected(.unknownCommand("")))  // 空命令
        #expect(router.handle(url: URL(string: "butler://volume/up/extra")!, executor: center)
            == .rejected(.unknownCommand("volume/up/extra")))  // 深路径不属于白名单形态
    }

    @Test func poisonedParametersAreRejectedBeforeExecutor() {
        let recorder = Recorder()
        let center = ActionCenter(executor: { action, _ in
            recorder.record(action.id)
            return .performed
        })
        let router = ButlerURLRouter()
        // 带毒参数：越界值（结构化 invalidValue，钉死参数名与原值）
        #expect(router.handle(url: URL(string: "butler://volume/set?value=101")!, executor: center)
            == .rejected(.invalidValue(parameter: "value", value: "101")))
        #expect(router.handle(url: URL(string: "butler://fan/rpm?value=999")!, executor: center)
            == .rejected(.invalidValue(parameter: "value", value: "999")))
        // 规格外参数/夹带私货/未知 flag（forbidden——只验类别，不锚文案）
        for url in ["butler://volume/set?value=50&unit=db", "butler://volume/up?value=1",
                    "butler://panel/show?x=1", "butler://status?xml=1"] {
            guard case .rejected(.forbidden) = router.handle(url: URL(string: url)!, executor: center) else {
                Issue.record("\(url) 应被 forbidden 拒绝")
                continue
            }
        }
        #expect(recorder.snapshot.isEmpty)  // 拒绝路径绝不触碰执行器
    }

    @Test func executorRejectionStaysInsideHandled() {
        // 执行器侧拒绝（权限/可用性裁决）≠ 解析拒绝：必须在 .handled 内上抛——
        // AU-01 的"静默"日志要能区分"命令面问题"与"执行面问题"（CLI 侧 1 与 3 的分界）
        let center = ActionCenter(executor: { _, _ in .rejected(reason: "未授权") })
        let router = ButlerURLRouter()
        #expect(router.handle(url: URL(string: "butler://fan/max")!, executor: center)
            == .handled(.rejected(reason: "未授权")))
    }
}

// MARK: - CLI 引擎 · status 家族（AU-03/AU-04）

@Suite struct CLIEngineStatusTests {
    @Test func humanStatusIsMultiLineAndReadable() {
        let outcome = CLIEngine.run(
            arguments: ["status"],
            snapshotReader: { makeSnapshot() },
            actionExecutor: { _ in .performed }
        )
        guard case .printed(let text) = outcome else {
            Issue.record("status 应输出文本，实际：\(outcome)")
            return
        }
        #expect(text.split(separator: "\n").count >= 7)  // 人类可读多行
        #expect(text.contains("电池：85%（充电中）"))
        #expect(text.contains("网络：Wi-Fi Home-5G（信号 4/4）"))
        #expect(text.contains("音量：50%"))
        #expect(text.contains("最高温度：45.3°C"))
        #expect(text.contains("风扇均速：2400 RPM"))
        #expect(text.contains("网速：入 1.2 MB/s · 出 89.0 KB/s"))
    }

    @Test func humanStatusMarksMissingDomainsHonestly() {
        // nil 域 = 主 App 尚未产出（快照契约），显示 "—" 而非伪装成 0
        let sparse = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_760_000_000))
        let outcome = CLIEngine.run(arguments: ["status"], snapshotReader: { sparse }, actionExecutor: { _ in .performed })
        guard case .printed(let text) = outcome else {
            Issue.record("缺省快照的 status 应仍可输出，实际：\(outcome)")
            return
        }
        for line in ["电池：—", "网络：—", "音量：—", "最高温度：—", "风扇均速：—", "网速：—"] {
            #expect(text.contains(line), "缺省域行：\(line)")
        }
        // unavailable/offline 是"有数据但读不到/断开"，与 nil 的 "—" 分开表述
        let partial = WidgetSnapshot(generatedAt: sparse.generatedAt, battery: .unavailable, link: .offline)
        guard case .printed(let text2) = CLIEngine.run(
            arguments: ["status"], snapshotReader: { partial }, actionExecutor: { _ in .performed }
        ) else {
            Issue.record("部分域快照的 status 应输出文本")
            return
        }
        #expect(text2.contains("电池：不可用"))
        #expect(text2.contains("网络：离线"))
    }

    @Test func jsonStatusRoundTripsThroughPlainJSONDecoder() {
        let snapshot = makeSnapshot()
        let outcome = CLIEngine.run(
            arguments: ["status", "--json"],
            snapshotReader: { snapshot },
            actionExecutor: { _ in .performed }
        )
        guard case .printed(let text) = outcome else {
            Issue.record("status --json 应输出 JSON，实际：\(outcome)")
            return
        }
        // 默认策略 JSONDecoder 无配置解回——对外契约零自定义编码策略（AU-04：仅状态字段）
        let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: Data(text.utf8))
        #expect(decoded == snapshot)
    }

    @Test func missingSnapshotExitsTwoAndErrorPayloadIsPinned() {
        // 快照缺省（主 App 未运行）：文本与 JSON 两种模式同归码 2
        #expect(CLIEngine.run(arguments: ["status", "--json"], snapshotReader: { nil }, actionExecutor: { _ in .performed })
            == .exitCode(CLIEngine.snapshotUnavailableCode))
        #expect(CLIEngine.run(arguments: ["status"], snapshotReader: { nil }, actionExecutor: { _ in .performed })
            == .exitCode(2))
        // 标准错误载荷形态（薄壳在码 2 + --json 时打到 stdout；脚本统一按 JSON 解析）
        let payload = try? JSONDecoder().decode([String: String].self, from: Data(CLIEngine.appNotRunningJSON.utf8))
        #expect(payload == ["error": "app-not-running"])
    }
}

// MARK: - CLI 引擎 · 帮助/动词/退出码（AU-01 白名单同源、AU-03 规约表）

@Suite struct CLIEngineVerbTests {
    @Test func helpListsEveryWhitelistedVerb() {
        // 帮助的白名单段自动生成自 ButlerCommand.allowed——三者（--help/-h/help）都必须全量列出
        for args in [["--help"], ["-h"], ["help"]] {
            guard case .printed(let text) = CLIEngine.run(
                arguments: args, snapshotReader: { nil }, actionExecutor: { _ in .performed }
            ) else {
                Issue.record("\(args) 应输出帮助")
                continue
            }
            for verb in ButlerCommand.allowed {
                #expect(text.contains(verb), "\(args) 帮助缺白名单动词 \(verb)")
            }
            #expect(text.contains("statusbutler"))
            #expect(text.contains("退出码"))  // 退出码规约随帮助同行（AU-05 速查卡片口径）
        }
    }

    @Test func emptyArgumentsShowHelp() {
        // 空命令行 = 速查文本（交互友好，退出码 0）；帮助是仅有的白名单外入口
        let empty = CLIEngine.run(arguments: [], snapshotReader: { nil }, actionExecutor: { _ in .performed })
        let help = CLIEngine.run(arguments: ["--help"], snapshotReader: { nil }, actionExecutor: { _ in .performed })
        #expect(empty == help)
        #expect(CLIEngine.exitCode(for: empty) == 0)
    }

    @Test func verbsReuseButlerCommandParsing() {
        // 动词面零自研：全部复用 ButlerCommand.parse（数值捷径归位 volume/set）
        let recorder = Recorder()
        let outcome = CLIEngine.run(
            arguments: ["volume", "50"],
            snapshotReader: { nil },
            actionExecutor: { command in
                recorder.record("\(command.verb)|\(command.args["value"] ?? "")")
                return .performed
            }
        )
        #expect(recorder.snapshot == ["volume/set|50"])
        guard case .printed(let text) = outcome else {
            Issue.record("volume 50 应成功回执，实际：\(outcome)")
            return
        }
        #expect(text.contains("volume/set"))
    }

    @Test func everyVerbFamilyRoutesAndReceipts() {
        // 各动词族抽样：进执行器的是白名单命令，且成功回执可锚定
        let cases: [[String]] = [
            ["mute"], ["volume", "up"], ["volume", "set", "30"],
            ["fan", "auto"], ["fan", "4000"], ["slot", "cycle"],
            ["theme", "apply", "极简"], ["screen", "off"], ["panel", "thermal"],
            ["bluetooth", "connect", "AirPods Pro"],
        ]
        for argv in cases {
            let recorder = Recorder()
            let outcome = CLIEngine.run(
                arguments: argv,
                snapshotReader: { nil },
                actionExecutor: { command in
                    recorder.record(command.verb)
                    return .performed
                }
            )
            guard case .printed(let text) = outcome else {
                Issue.record("\(argv) 应成功回执，实际：\(outcome)")
                continue
            }
            #expect(!recorder.snapshot.isEmpty, "\(argv) 未进执行器")
            #expect(ButlerCommand.allowed.contains(recorder.snapshot[0]), "\(argv) 进了非白名单动词")
            #expect(text.contains("已执行"), "\(argv) 回执缺「已执行」")
        }
    }

    @Test func forwardedToAppCountsAsSuccessForThinCLI() {
        // AU-03 薄壳转发形态：送达主 App 即成功——主 App 内部成败对 CLI 进程不可见
        let outcome = CLIEngine.run(
            arguments: ["volume", "up"],
            snapshotReader: { nil },
            actionExecutor: { _ in .forwardedToApp(actionID: "volume") }
        )
        guard case .printed(let text) = outcome else {
            Issue.record("转发成功应输出回执，实际：\(outcome)")
            return
        }
        #expect(text.contains("已转发到主 App：volume"))
        #expect(CLIEngine.exitCode(for: outcome) == 0)
    }

    @Test func failuresExitWithSpecifiedCodes() {
        let executed: (ButlerCommand) -> ActionOutcome = { _ in .performed }
        // 1 未知命令：白名单外动词死在第一参数上
        #expect(CLIEngine.run(arguments: ["sudo", "rm", "-rf", "/"], snapshotReader: { nil }, actionExecutor: executed)
            == .exitCode(1))
        #expect(CLIEngine.run(arguments: ["osascript", "-e", "tell app \"Finder\" to quit"], snapshotReader: { nil }, actionExecutor: executed)
            == .exitCode(1))
        // 3 被拒：参数越界（parse 校验）
        #expect(CLIEngine.run(arguments: ["volume", "101"], snapshotReader: { nil }, actionExecutor: executed)
            == .exitCode(3))
        // 3 被拒：无参动词带多余位置参数（规格外）
        #expect(CLIEngine.run(arguments: ["volume", "up", "50"], snapshotReader: { nil }, actionExecutor: executed)
            == .exitCode(3))
        // 3 被拒：执行器裁决拒绝（权限/可用性）
        #expect(CLIEngine.run(arguments: ["fan", "max"], snapshotReader: { nil }, actionExecutor: { _ in .rejected(reason: "未装 Helper") })
            == .exitCode(3))
    }

    @Test func exitCodeTableIsPinned() {
        // 规约全表：0 成功 / 1 未知命令 / 2 快照不可用 / 3 被拒——薄壳 main 与测试共用同一张表
        #expect(CLIEngine.exitCode(for: CLIOutcome.printed("x")) == 0)
        for code: Int32 in [1, 2, 3] {
            #expect(CLIEngine.exitCode(for: CLIOutcome.exitCode(code)) == code)
        }
        #expect(CLIEngine.snapshotUnavailableCode == 2)
        #expect(CLIEngine.exitCode(for: CommandError.unknownCommand("rm")) == 1)
        #expect(CLIEngine.exitCode(for: CommandError.invalidValue(parameter: "value", value: "101")) == 3)
        #expect(CLIEngine.exitCode(for: CommandError.forbidden("x")) == 3)
        #expect(CLIEngine.exitCode(for: ActionOutcome.performed) == 0)
        #expect(CLIEngine.exitCode(for: ActionOutcome.forwardedToApp(actionID: "volume")) == 0)
        #expect(CLIEngine.exitCode(for: ActionOutcome.rejected(reason: "r")) == 3)
    }
}

// MARK: - 执行器绑定构建器（AC-05 同源钉死）

/// 宽接口假实现：记录调用并返回注入结果（真实系统操作由集成方注入——测试只验接线形状）
private final class FakeAutomationStore: AutomationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func setVolume(level: Int) -> ActionOutcome {
        lock.lock(); defer { lock.unlock() }
        calls.append("setVolume(\(level))")
        return .performed
    }

    func toggleMute() -> ActionOutcome {
        lock.lock(); defer { lock.unlock() }
        calls.append("toggleMute")
        return .performed
    }

    var recordedCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

@Suite struct AutomationGlueTests {
    @Test func bindingKeysExactlyCoverTheRegistry() {
        // AC-05 同源钉死：绑定表键域 = 注册表 id 域，不多不少（面板/URL/CLI 三处喂一张动作表）
        let bindings = AutomationGlue.executorBindings(store: FakeAutomationStore())
        #expect(Set(bindings.keys) == Set(ActionRegistry.builtin.map(\.id)))
        #expect(bindings.count == ActionRegistry.builtin.count)
    }

    @Test func volumeExampleWiresThroughTheStore() {
        // 示例实现的真实接线形状：绑定 → 宽接口通道，结果原样上抛
        let store = FakeAutomationStore()
        let bindings = AutomationGlue.executorBindings(store: store)
        #expect(bindings["volume"]?(ButlerCommand(verb: "volume/set", args: ["value": "42"])) == .performed)
        #expect(bindings["mute"]?(ButlerCommand(verb: "volume/mute")) == .performed)
        #expect(store.recordedCalls == ["setVolume(42)", "toggleMute"])
    }

    @Test func volumeBindingDefendsAgainstDirectlyBuiltCommands() {
        // 绕过 parse 直构的带毒 value：Int 解不出即拒绝，绝不进 store（同 resolve 的纵深防御）
        let store = FakeAutomationStore()
        let bindings = AutomationGlue.executorBindings(store: store)
        guard case .rejected = bindings["volume"]?(ButlerCommand(verb: "volume/set", args: ["value": "50%; rm -rf /"])) else {
            Issue.record("带毒 value 应被拒绝")
            return
        }
        #expect(store.recordedCalls.isEmpty)
    }

    @Test func volumeUpDownAwaitSteppingChannel() {
        // 音量步进是示例中唯一留 TODO 的分支：诚实拒绝并说明缺读通道，不伪装成功
        let store = FakeAutomationStore()
        let bindings = AutomationGlue.executorBindings(store: store)
        guard case .rejected(let reason) = bindings["volume"]?(ButlerCommand(verb: "volume/up")) else {
            Issue.record("volume/up 骨架应拒绝")
            return
        }
        #expect(reason.contains("步进"))
        #expect(store.recordedCalls.isEmpty)
    }

    @Test func unwiredActionsRejectHonestlyPerAvailability() {
        // 未接线动作按注册表 availability 分级给拒绝理由（AC-02：诚实分级，拒绝时说清为什么）
        let bindings = AutomationGlue.executorBindings(store: FakeAutomationStore())
        guard case .rejected(let fanReason) = bindings["fan-max"]?(ButlerCommand(verb: "fan/max")) else {
            Issue.record("fan-max 骨架应拒绝")
            return
        }
        #expect(fanReason.contains("未接线"))
        guard case .rejected(let darkReason) = bindings["darkmode"]?(ButlerCommand(verb: "darkmode/toggle")) else {
            Issue.record("darkmode 骨架应拒绝")
            return
        }
        #expect(darkReason.contains("辅助功能"))  // needsPermission 动作带权限名
        guard case .rejected(let dndReason) = bindings["dnd"]?(ButlerCommand(verb: "dnd/toggle")) else {
            Issue.record("dnd 骨架应拒绝")
            return
        }
        #expect(dndReason.contains("深链"))  // deepLinkOnly 动作明确不开放命令执行
        // 除示例音量域外，其余绑定在骨架半场一律拒绝（未接线 = 不存在执行面）
        for (id, binding) in bindings where id != "volume" && id != "mute" {
            guard case .rejected = binding(ButlerCommand(verb: "probe/\(id)")) else {
                Issue.record("\(id) 骨架应拒绝而非执行")
                continue
            }
        }
    }

    @Test func statusActionPointsToSnapshotChannel() {
        // status 是只读查询：不经执行器，指路 CLI 快照通道（AU-03/AU-04 查询零副作用）
        let bindings = AutomationGlue.executorBindings(store: FakeAutomationStore())
        guard case .rejected(let reason) = bindings["status"]?(ButlerCommand(verb: "status")) else {
            Issue.record("status 绑定应拒绝 URL/执行器通道")
            return
        }
        #expect(reason.contains("只读"))
    }
}
