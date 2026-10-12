import Testing
import Foundation
@testable import StatusButlerCore

// T-034: 动作中心引擎 + butler:// / CLI 命令解析层（A9·AC-02~05 / AU-01~04）
// 纪律：执行器为测试注入的假实现；解析/路由层零系统调用，任何"任意执行"形状都必须被拒

// 锁保护以满足 @Sendable 执行器闭包的捕获（Swift Testing 用例并行）
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

private func expectForbidden(_ result: Result<ButlerCommand, CommandError>?, _ source: String) {
    guard case .some(.failure(.forbidden)) = result else {
        Issue.record("\(source) 应被 forbidden 拒绝，实际：\(String(describing: result))")
        return
    }
}

// MARK: - URL Scheme 解析

@Suite struct ButlerURLParsingTests {
    @Test func parsesEveryWhitelistedVerb() {
        let cases: [(url: String, verb: String, args: [String: String])] = [
            ("butler://volume/up", "volume/up", [:]),
            ("butler://volume/down", "volume/down", [:]),
            ("butler://volume/mute", "volume/mute", [:]),
            ("butler://volume/set?value=50", "volume/set", ["value": "50"]),
            ("butler://panel/show", "panel/show", [:]),
            ("butler://panel/thermal", "panel/thermal", [:]),
            ("butler://panel/battery", "panel/battery", [:]),
            ("butler://panel/network", "panel/network", [:]),
            ("butler://bluetooth/connect?device=AirPods", "bluetooth/connect", ["device": "AirPods"]),
            ("butler://fan/auto", "fan/auto", [:]),
            ("butler://fan/max", "fan/max", [:]),
            ("butler://fan/rpm?value=4000", "fan/rpm", ["value": "4000"]),
            ("butler://slot/cycle", "slot/cycle", [:]),
            ("butler://theme/apply?name=minimal", "theme/apply", ["name": "minimal"]),
            ("butler://screen/off", "screen/off", [:]),
            ("butler://status", "status", [:]),
        ]
        for c in cases {
            #expect(
                ButlerCommand.parse(URL(string: c.url)!) == .success(ButlerCommand(verb: c.verb, args: c.args)),
                "解析 \(c.url)"
            )
        }
    }

    @Test func ignoresForeignSchemes() {
        // 非 butler scheme 一律 nil（不归我们管）；butler-debug 防前缀混淆
        for s in ["https://example.com/volume/up", "mailto:x@y.z", "file:///volume/up",
                  "shortcuts://run?name=x", "butler-debug://volume/up"] {
            #expect(ButlerCommand.parse(URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func rejectsUnknownVerbs() {
        let cases: [(url: String, verb: String)] = [
            ("butler://volume/boost", "volume/boost"),
            ("butler://reboot", "reboot"),
            ("butler://rm/rf", "rm/rf"),
            ("butler://volume", "volume"),                  // 缺限定词
            ("butler://", ""),                               // 空命令
            ("butler://volume/up/extra", "volume/up/extra"), // 深路径不属于白名单形态
        ]
        for c in cases {
            #expect(
                ButlerCommand.parse(URL(string: c.url)!) == .failure(.unknownCommand(c.verb)),
                "解析 \(c.url)"
            )
        }
    }

    @Test func validatesVolumeSetValue() {
        func parse(value raw: String) -> Result<ButlerCommand, CommandError>? {
            ButlerCommand.parse(URL(string: "butler://volume/set?value=\(raw)")!)
        }
        #expect(parse(value: "0") == .success(ButlerCommand(verb: "volume/set", args: ["value": "0"])))
        #expect(parse(value: "100") == .success(ButlerCommand(verb: "volume/set", args: ["value": "100"])))
        for bad in ["101", "-1", "50.5", "abc"] {
            #expect(parse(value: bad) == .failure(.invalidValue(parameter: "value", value: bad)), "\(bad)")
        }
        // 缺参按非法值处理（不是 forbidden）
        #expect(
            ButlerCommand.parse(URL(string: "butler://volume/set")!)
                == .failure(.invalidValue(parameter: "value", value: ""))
        )
    }

    @Test func validatesFanRpmBounds() {
        func parse(value raw: String) -> Result<ButlerCommand, CommandError>? {
            ButlerCommand.parse(URL(string: "butler://fan/rpm?value=\(raw)")!)
        }
        #expect(parse(value: "1000") == .success(ButlerCommand(verb: "fan/rpm", args: ["value": "1000"])))
        #expect(parse(value: "15000") == .success(ButlerCommand(verb: "fan/rpm", args: ["value": "15000"])))
        for bad in ["999", "15001", "4000.5", "fast"] {
            #expect(parse(value: bad) == .failure(.invalidValue(parameter: "value", value: bad)), "\(bad)")
        }
    }

    @Test func decodesPercentEncodedParams() {
        let bluetooth = ButlerCommand.parse(URL(string: "butler://bluetooth/connect?device=AirPods%20Pro")!)
        #expect(bluetooth == .success(ButlerCommand(verb: "bluetooth/connect", args: ["device": "AirPods Pro"])))

        // 非 ASCII 主题名同样要解回原文
        var components = URLComponents()
        components.scheme = "butler"
        components.host = "theme"
        components.path = "/apply"
        components.queryItems = [URLQueryItem(name: "name", value: "极简")]
        let theme = ButlerCommand.parse(components.url!)
        #expect(theme == .success(ButlerCommand(verb: "theme/apply", args: ["name": "极简"])))
    }

    @Test func rejectsUnexpectedParams() {
        // 最小参数面：无参动词带参、只读命令带未知 flag、参数动词夹带私货——全部 forbidden
        expectForbidden(ButlerCommand.parse(URL(string: "butler://volume/up?value=50")!), "volume/up?value=50")
        expectForbidden(ButlerCommand.parse(URL(string: "butler://panel/show?x=1")!), "panel/show?x=1")
        expectForbidden(ButlerCommand.parse(URL(string: "butler://status?xml=1")!), "status?xml=1")
        expectForbidden(ButlerCommand.parse(URL(string: "butler://volume/set?value=50&unit=db")!), "volume/set 夹带 unit")
    }

    @Test func verbMatchingIsCaseInsensitive() {
        #expect(
            ButlerCommand.parse(URL(string: "BUTLER://Volume/UP")!)
                == .success(ButlerCommand(verb: "volume/up"))
        )
    }
}

// MARK: - CLI 解析（statusbutler）

@Suite struct ButlerCLIParsingTests {
    @Test func volumeMapsToSetCommand() {
        #expect(
            ButlerCommand.parse(arguments: ["volume", "50"])
                == .success(ButlerCommand(verb: "volume/set", args: ["value": "50"]))
        )
        #expect(
            ButlerCommand.parse(arguments: ["volume", "set", "50"])
                == .success(ButlerCommand(verb: "volume/set", args: ["value": "50"]))
        )
        #expect(ButlerCommand.parse(arguments: ["volume", "up"]) == .success(ButlerCommand(verb: "volume/up")))
        // CLI 侧同样过参数校验
        #expect(
            ButlerCommand.parse(arguments: ["volume", "101"])
                == .failure(.invalidValue(parameter: "value", value: "101"))
        )
    }

    @Test func muteShortcuts() {
        #expect(ButlerCommand.parse(arguments: ["mute"]) == .success(ButlerCommand(verb: "volume/mute")))
        #expect(ButlerCommand.parse(arguments: ["volume", "mute"]) == .success(ButlerCommand(verb: "volume/mute")))
        #expect(ButlerCommand.parse(arguments: ["volume", "down"]) == .success(ButlerCommand(verb: "volume/down")))
    }

    @Test func statusJsonFlagParses() {
        #expect(ButlerCommand.parse(arguments: ["status"]) == .success(ButlerCommand(verb: "status")))
        #expect(
            ButlerCommand.parse(arguments: ["status", "--json"])
                == .success(ButlerCommand(verb: "status", args: ["json": "true"]))
        )
        expectForbidden(ButlerCommand.parse(arguments: ["status", "verbose"]), "status verbose")
    }

    @Test func fanSlotPanelScreenForms() {
        #expect(ButlerCommand.parse(arguments: ["fan", "auto"]) == .success(ButlerCommand(verb: "fan/auto")))
        #expect(ButlerCommand.parse(arguments: ["fan", "max"]) == .success(ButlerCommand(verb: "fan/max")))
        #expect(
            ButlerCommand.parse(arguments: ["fan", "4000"])
                == .success(ButlerCommand(verb: "fan/rpm", args: ["value": "4000"]))
        )
        #expect(
            ButlerCommand.parse(arguments: ["fan", "rpm", "4000"])
                == .success(ButlerCommand(verb: "fan/rpm", args: ["value": "4000"]))
        )
        #expect(
            ButlerCommand.parse(arguments: ["fan", "rpm", "900"])
                == .failure(.invalidValue(parameter: "value", value: "900"))
        )
        #expect(ButlerCommand.parse(arguments: ["slot", "cycle"]) == .success(ButlerCommand(verb: "slot/cycle")))
        #expect(ButlerCommand.parse(arguments: ["panel", "thermal"]) == .success(ButlerCommand(verb: "panel/thermal")))
        #expect(ButlerCommand.parse(arguments: ["screen", "off"]) == .success(ButlerCommand(verb: "screen/off")))
    }

    @Test func rejectsInvalidCommandLine() {
        #expect(ButlerCommand.parse(arguments: []) == nil)  // 空命令行不归解析器管
        #expect(ButlerCommand.parse(arguments: ["sudo", "rm", "-rf", "/"]) == .failure(.unknownCommand("sudo")))
        // 任意执行形状必须死在第一参数上
        #expect(
            ButlerCommand.parse(arguments: ["osascript", "-e", "tell app \"Finder\" to quit"])
                == .failure(.unknownCommand("osascript"))
        )
        #expect(ButlerCommand.parse(arguments: ["volume", "boost"]) == .failure(.unknownCommand("volume/boost")))
        #expect(
            ButlerCommand.parse(arguments: ["volume", "set"]) == .failure(.invalidValue(parameter: "value", value: ""))
        )
        expectForbidden(ButlerCommand.parse(arguments: ["volume", "up", "50"]), "volume up 50")
    }

    @Test func bluetoothAndThemePositionalParams() {
        #expect(
            ButlerCommand.parse(arguments: ["bluetooth", "connect", "AirPods Pro"])
                == .success(ButlerCommand(verb: "bluetooth/connect", args: ["device": "AirPods Pro"]))
        )
        #expect(
            ButlerCommand.parse(arguments: ["bluetooth", "connect"])
                == .failure(.invalidValue(parameter: "device", value: ""))
        )
        #expect(
            ButlerCommand.parse(arguments: ["theme", "apply", "极简"])
                == .success(ButlerCommand(verb: "theme/apply", args: ["name": "极简"]))
        )
    }
}

// MARK: - 命令 → 动作路由

@Suite struct ButlerResolveTests {
    @Test func mapsCommandsToRegistryActions() {
        let cases: [(verb: String, actionID: String)] = [
            ("volume/up", "volume"), ("volume/down", "volume"),
            ("volume/set", "volume"), ("volume/mute", "mute"),
            ("panel/show", "panel"), ("panel/thermal", "panel"),
            ("panel/battery", "panel"), ("panel/network", "panel"),
            ("bluetooth/connect", "bluetooth-connect"),
            ("fan/auto", "fan-max"), ("fan/max", "fan-max"), ("fan/rpm", "fan-max"),
            ("slot/cycle", "slot-cycle"),
            ("theme/apply", "theme"),
            ("screen/off", "screen-off"),
            ("status", "status"),
        ]
        for c in cases {
            #expect(
                ButlerCommand.resolve(ButlerCommand(verb: c.verb)) == .forwardedToApp(actionID: c.actionID),
                "\(c.verb)"
            )
        }
    }

    @Test func rejectsCommandsOutsideWhitelist() {
        // 直构命令（绕过 parse）也必须在路由层被拒——纵深防御
        for verb in ["rm", "osascript", "volume/set value=1; rm -rf /", ""] {
            guard case .rejected = ButlerCommand.resolve(ButlerCommand(verb: verb)) else {
                Issue.record("\(verb) 应被拒绝")
                continue
            }
        }
    }

    @Test func everyAllowedVerbRoutesToRegisteredAction() {
        // AC-05 同源不变量：白名单动词必须全部路由到注册表内真实动作，一个不落
        for verb in ButlerCommand.allowed {
            guard case .forwardedToApp(let actionID) = ButlerCommand.resolve(ButlerCommand(verb: verb)) else {
                Issue.record("\(verb) 未路由到动作")
                continue
            }
            #expect(ActionRegistry.action(id: actionID) != nil, "\(verb) → \(actionID) 不在注册表")
        }
    }
}

// MARK: - 动作注册表

@Suite struct ActionRegistryTests {
    @Test func containsFirstBatchWithUniqueIDs() {
        let ids = ActionRegistry.builtin.map(\.id)
        #expect(Set(ids).count == ids.count)  // 面板/URL/CLI 三处寻址的 key，必须唯一
        for id in ["volume", "mute", "wifi-toggle", "bluetooth-toggle", "darkmode",
                   "fan-max", "screen-off", "panel", "slot-cycle", "speedtest", "healthcheck"] {
            #expect(ids.contains(id), "缺少首批动作 \(id)")
        }
    }

    @Test func marksAvailabilityHonestly() {
        // AC-02 诚实分级的关键标注
        #expect(ActionRegistry.action(id: "darkmode")?.availability == .needsPermission("辅助功能"))
        #expect(ActionRegistry.action(id: "dnd")?.availability == .deepLinkOnly)  // 无公开 API，只深链
        #expect(ActionRegistry.action(id: "fan-max")?.availability == .needsPermission("特权 Helper"))
        for id in ["volume", "mute", "wifi-toggle", "bluetooth-toggle", "screen-off",
                   "panel", "slot-cycle", "speedtest", "healthcheck"] {
            #expect(ActionRegistry.action(id: id)?.availability == .available, "\(id) 应为 available")
        }
    }

    @Test func lookupUnknownActionReturnsNil() {
        #expect(ActionRegistry.action(id: "nope") == nil)
        #expect(ActionRegistry.action(id: "") == nil)
    }
}

// MARK: - 动作中心引擎（注入执行器）

@Suite struct ActionCenterEngineTests {
    @Test func routesURLThroughInjectedExecutor() {
        let recorder = Recorder()
        let center = ActionCenter(executor: { action, command in
            recorder.record("\(action.id)|\(command.verb)|\(command.args["value"] ?? "")")
            return .performed
        })
        #expect(center.perform(url: URL(string: "butler://volume/set?value=50")!) == .performed)
        #expect(center.perform(url: URL(string: "butler://panel/show")!) == .performed)
        #expect(recorder.snapshot == ["volume|volume/set|50", "panel|panel/show|"])
    }

    @Test func rejectsInvalidURLWithoutCallingExecutor() {
        let recorder = Recorder()
        let center = ActionCenter(executor: { action, _ in
            recorder.record(action.id)
            return .performed
        })
        for url in ["butler://volume/set?value=999", "butler://rm/rf", "butler://volume/up?value=1"] {
            guard let outcome = center.perform(url: URL(string: url)!) else {
                Issue.record("\(url) 不应返回 nil")
                continue
            }
            guard case .rejected = outcome else {
                Issue.record("\(url) 应被拒绝，实际：\(outcome)")
                continue
            }
        }
        #expect(recorder.snapshot.isEmpty)  // 拒绝路径绝不触碰执行器
    }

    @Test func ignoresForeignSchemeURLs() {
        let center = ActionCenter(executor: { _, _ in .performed })
        #expect(center.perform(url: URL(string: "https://example.com/volume/up")!) == nil)
        #expect(center.perform(url: URL(string: "shortcuts://run?name=x")!) == nil)
    }

    @Test func executorDecidesOutcomeByAvailability() {
        // 可用性/权限的裁决点在注入的执行器（引擎只做路由，不替执行器做决定）
        let center = ActionCenter(executor: { action, _ in
            if case .needsPermission = action.availability {
                return .rejected(reason: "未授权：\(action.id)")
            }
            return .performed
        })
        guard let denied = center.perform(url: URL(string: "butler://fan/max")!) else {
            Issue.record("butler:// 命令不应返回 nil")
            return
        }
        guard case .rejected = denied else {
            Issue.record("fan/max 应被执行器按 needsPermission 拒绝，实际：\(denied)")
            return
        }
        #expect(center.perform(url: URL(string: "butler://volume/up")!) == .performed)
    }
}
