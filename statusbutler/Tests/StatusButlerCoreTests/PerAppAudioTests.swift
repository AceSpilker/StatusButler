import Foundation
import Testing
@testable import StatusButlerCore

// T-050: 每 App 音量用户态半场——增益钳制/静音优先/规则引擎/驱动状态机全转移/
// 直通保护/FakeMixer 生命周期与幂等（A11 E20 PAV-01~05）
@Suite struct PerAppAudioTests {

    // MARK: - 增益钳制与静音优先

    @Test func channelGainAndCapAreClampedOnInit() {
        #expect(PerAppChannel(bundleID: "a", displayName: "A", gainPercent: -10).gainPercent == 0)
        #expect(PerAppChannel(bundleID: "a", displayName: "A", gainPercent: 150).gainPercent == 100)
        #expect(PerAppChannel(bundleID: "a", displayName: "A", gainPercent: 55).gainPercent == 55)
        // 通道级上限与规则上限同样钳制：脏持久化数据不进引擎
        #expect(PerAppChannel(bundleID: "a", displayName: "A", gainPercent: 50, ruleCap: 130).ruleCap == 100)
        #expect(PerAppChannel(bundleID: "a", displayName: "A", gainPercent: 50, ruleCap: -5).ruleCap == 0)
        #expect(PerAppRule(match: "x", maxGain: 999).maxGain == 100)
    }

    @Test func muteWinsOverGainCapAndBoost() {
        let muted = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 100, isMuted: true)
        let rules = [PerAppRule(match: "a.b.c", boostWhenFocused: true)]
        // 静音压过一切：目标增益 0（驱动侧零增益），上限/焦点抬升都不参与
        #expect(PerAppRuleEngine.effectiveGain(of: muted, rules: rules, focusedBundleID: "a.b.c") == 0)
        let gains = PerAppRuleEngine.applyRules(channels: [muted], rules: rules, focusedBundleID: "a.b.c")
        #expect(gains["a.b.c"] == 0)
    }

    // MARK: - 规则引擎

    @Test func ruleCapLimitsGain() {
        let rules = [PerAppRule(match: "com.spotify.client", maxGain: 30)]
        // 上限之上压到 30
        let high = PerAppRuleEngine.applyRules(
            channels: [PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 80)],
            rules: rules)
        #expect(high["com.spotify.client"] == 30)
        // 上限之下原样通过
        let low = PerAppRuleEngine.applyRules(
            channels: [PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 20)],
            rules: rules)
        #expect(low["com.spotify.client"] == 20)
    }

    @Test func focusBoostAddsTwentyAndCapsAtHundred() {
        let channel = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 85)
        let rules = [PerAppRule(match: "a.b.c", boostWhenFocused: true)]
        // 85 + 20 封顶 100，不越界
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: rules, focusedBundleID: "a.b.c") == 100)
        // 非焦点 App / 无焦点信息：不抬升
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: rules, focusedBundleID: nil) == 85)
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: rules, focusedBundleID: "other.app") == 85)
    }

    @Test func focusBoostNeedsRuleFlagEvenWhenFocused() {
        let channel = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 50)
        // 抬升必须显式 opt-in：规则不带 flag 或完全没有规则都不抬
        let plain = [PerAppRule(match: "a.b.c", maxGain: 100)]
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: plain, focusedBundleID: "a.b.c") == 50)
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: [], focusedBundleID: "a.b.c") == 50)
    }

    @Test func boostNeverBreaksHardCap() {
        // "永不超过 80%"：焦点抬升也只能在帽内消化
        let rules = [PerAppRule(match: "a.b.c", maxGain: 80, boostWhenFocused: true)]
        let atCap = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 80)
        #expect(PerAppRuleEngine.effectiveGain(of: atCap, rules: rules, focusedBundleID: "a.b.c") == 80)
        // 帽下余量场景：40 → 60（抬升可见但不越帽）
        let low = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 40)
        #expect(PerAppRuleEngine.effectiveGain(of: low, rules: rules, focusedBundleID: "a.b.c") == 60)
    }

    @Test func strictestCapWinsAmongConflictingRules() {
        let channel = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 100)
        let rules = [
            PerAppRule(match: "a.b.c", maxGain: 70),  // bundleID 命中
            PerAppRule(match: "C", maxGain: 30),      // 显示名命中，更严
            PerAppRule(match: "unrelated", maxGain: 10),  // 不命中，不参与
        ]
        // 多规则冲突取最严：30，而不是后写的或先写的
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: rules) == 30)
    }

    @Test func noRulesMeansUserGainUnlimited() {
        let gains = PerAppRuleEngine.applyRules(
            channels: [PerAppChannel(bundleID: "a.b", displayName: "A", gainPercent: 100)],
            rules: [])
        #expect(gains["a.b"] == 100)  // 无规则默认不设限：用户滑杆即最终值
        #expect(PerAppRuleEngine.applyRules(channels: [], rules: [PerAppRule(match: "x", maxGain: 10)]).isEmpty)
    }

    @Test func matchHitsBundleIDOrDisplayName() {
        let channel = PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 90)
        #expect(PerAppRuleEngine.matches(PerAppRule(match: "spotify"), channel))   // bundleID 子串
        #expect(PerAppRuleEngine.matches(PerAppRule(match: "SPOTIFY"), channel))   // 大小写不敏感
        #expect(PerAppRuleEngine.matches(PerAppRule(match: "Spo"), channel))       // 显示名子串
        #expect(!PerAppRuleEngine.matches(PerAppRule(match: "tidal"), channel))
    }

    @Test func blankMatchNeverMatches() {
        let channel = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 100)
        // 空/纯空白串会 contains 一切：必须拒绝，防隐形全局规则把所有 App 压到上限
        for blank in ["", "  ", "\n\t"] {
            let rules = [PerAppRule(match: blank, maxGain: 0)]
            #expect(!PerAppRuleEngine.matches(rules[0], channel))
            #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: rules) == 100)
        }
    }

    @Test func channelLevelCapJoinsStrictestContest() {
        let channel = PerAppChannel(bundleID: "a.b.c", displayName: "C", gainPercent: 100, ruleCap: 40)
        // 通道 cap 40 比规则 60 更严 → 40 生效
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: [PerAppRule(match: "a.b.c", maxGain: 60)]) == 40)
        // 规则 30 反超通道 cap → 30 生效
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: [PerAppRule(match: "a.b.c", maxGain: 30)]) == 30)
        // 无规则时通道 cap 单独生效
        #expect(PerAppRuleEngine.effectiveGain(of: channel, rules: []) == 40)
    }

    @Test func rememberedBundleIDsFollowRememberRules() {
        let channels = [
            PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 60),
            PerAppChannel(bundleID: "com.apple.Safari", displayName: "Safari", gainPercent: 70),
            PerAppChannel(bundleID: "com.tencent.xinWeChat", displayName: "微信", gainPercent: 80),
        ]
        let rules = [
            PerAppRule(match: "spotify", rememberPerApp: true),
            PerAppRule(match: "微信", maxGain: 90, rememberPerApp: true),
            PerAppRule(match: "Safari", maxGain: 50),  // 不带 remember 的规则不把 Safari 拉进落盘集合
        ]
        #expect(PerAppRuleEngine.rememberedBundleIDs(channels: channels, rules: rules)
            == ["com.spotify.client", "com.tencent.xinWeChat"])
        #expect(PerAppRuleEngine.rememberedBundleIDs(channels: channels, rules: []).isEmpty)
    }

    // MARK: - 驱动安装状态机（全转移表）

    /// 合法转移全集：测试与非法转移穷举共用同一张表，改转移必改两处断言。
    private static let validTransitions: [(state: DriverInstallState, event: DriverInstallEvent, expected: DriverInstallState)] = [
        // 未安装入口
        (.notInstalled, .userRequestedInstall, .installing),
        (.notInstalled, .driverDetected, .installed),
        (.notInstalled, .osUnsupportedDetected, .unsupportedOS),
        // 安装中
        (.installing, .approvalRequired, .needsUserApproval),
        (.installing, .driverDetected, .installed),
        (.installing, .installTimedOut, .failed("安装超时：驱动未在预期时间内激活")),
        (.installing, .installFailed("磁盘满"), .failed("磁盘满")),
        (.installing, .uninstallRequested, .notInstalled),
        // 待批准
        (.needsUserApproval, .approvalGranted, .installing),
        (.needsUserApproval, .approvalDenied, .failed("用户在系统设置中拒绝了系统扩展")),
        (.needsUserApproval, .installTimedOut, .failed("等待系统设置批准超时")),
        (.needsUserApproval, .uninstallRequested, .notInstalled),
        // 已安装
        (.installed, .uninstallRequested, .notInstalled),
        (.installed, .driverLost, .notInstalled),
        // 失败可重试/清理
        (.failed("x"), .userRequestedInstall, .installing),
        (.failed("x"), .uninstallRequested, .notInstalled),
    ]

    @Test func driverLifecycleCoversAllValidTransitions() {
        for t in Self.validTransitions {
            #expect(DriverLifecycle.next(state: t.state, event: t.event) == t.expected)
        }
    }

    @Test func driverLifecycleRejectsEveryIllegalCombination() {
        // 形状键去掉关联值载荷，穷举 6 状态 × 10 事件：不在合法表里的组合必须 nil
        func stateShape(_ s: DriverInstallState) -> String {
            if case .failed = s { return "failed" }
            return "\(s)"
        }
        func eventShape(_ e: DriverInstallEvent) -> String {
            if case .installFailed = e { return "installFailed" }
            return "\(e)"
        }
        let legal = Set(Self.validTransitions.map { stateShape($0.state) + "|" + eventShape($0.event) })
        let states: [DriverInstallState] = [
            .notInstalled, .installing, .needsUserApproval,
            .installed, .failed("x"), .unsupportedOS,
        ]
        let events: [DriverInstallEvent] = [
            .userRequestedInstall, .approvalRequired, .approvalGranted, .approvalDenied,
            .installTimedOut, .installFailed("x"), .driverDetected, .driverLost,
            .uninstallRequested, .osUnsupportedDetected,
        ]
        for state in states {
            for event in events
            where !legal.contains(stateShape(state) + "|" + eventShape(event)) {
                #expect(DriverLifecycle.next(state: state, event: event) == nil)
            }
        }
        // 典型非法时序点名：批准前驱动不可能激活；已安装不能再请求安装；终态无出口
        #expect(DriverLifecycle.next(state: .needsUserApproval, event: .driverDetected) == nil)
        #expect(DriverLifecycle.next(state: .installed, event: .userRequestedInstall) == nil)
        #expect(DriverLifecycle.next(state: .unsupportedOS, event: .userRequestedInstall) == nil)
    }

    @Test func driverLifecycleHappyPathReachesInstalled() throws {
        var state = DriverInstallState.notInstalled
        func step(_ event: DriverInstallEvent, _ expected: DriverInstallState) throws {
            let next = try #require(DriverLifecycle.next(state: state, event: event))
            #expect(next == expected)
            state = next
        }
        try step(.userRequestedInstall, .installing)
        try step(.approvalRequired, .needsUserApproval)
        try step(.approvalGranted, .installing)   // 批准≠上线：仍等驱动激活
        try step(.driverDetected, .installed)
        #expect(state.isDriverReady)
        try step(.uninstallRequested, .notInstalled)  // 一键卸载回到未安装（恢复原状）
        #expect(!state.isDriverReady)
    }

    @Test func failedStateCarriesReasonAndSupportsRetry() {
        let timedOut = DriverLifecycle.next(state: .installing, event: .installTimedOut)
        #expect(timedOut == .failed("安装超时：驱动未在预期时间内激活"))
        // 失败不是死胡同：向导允许原地重试
        #expect(DriverLifecycle.next(state: timedOut!, event: .userRequestedInstall) == .installing)
        #expect(!timedOut!.isDriverReady)
    }

    // MARK: - 直通保护（PAV-04）

    @Test func professionalAudioDetectionHitsKnownList() {
        let running: Set<String> = [
            "com.apple.Safari", "com.apple.logic10", "com.audinate.dvs", "com.tinyspeck.slack",
        ]
        let conflict = PassthroughGuard.detectPassthroughConflict(runningBundleIDs: running)
        #expect(conflict == ["com.apple.logic10", "com.audinate.dvs"])
        #expect(PassthroughGuard.shouldEnterPassthrough(runningBundleIDs: running))
        // 全等匹配不做子串：清单纯命名的变体不误伤
        #expect(!PassthroughGuard.shouldEnterPassthrough(runningBundleIDs: ["com.apple.logic10.demo"]))
    }

    @Test func ordinaryAppsNeverTriggerPassthrough() {
        let running: Set<String> = [
            "com.apple.Safari", "com.google.Chrome", "com.tinyspeck.slack", "com.spotify.client",
        ]
        #expect(PassthroughGuard.detectPassthroughConflict(runningBundleIDs: running).isEmpty)
        #expect(!PassthroughGuard.shouldEnterPassthrough(runningBundleIDs: running))
        #expect(!PassthroughGuard.shouldEnterPassthrough(runningBundleIDs: []))
    }

    @Test func professionalListMeetsSpecMinimum() {
        // E20 规格下限 ≥6，且点名四家必须在列（Logic/Pro Tools/Ableton/Dante）
        #expect(PassthroughGuard.professionalAudioBundleIDs.count >= 6)
        for must in ["com.apple.logic10", "com.avid.ProTools", "com.ableton.live", "com.audinate.dvs"] {
            #expect(PassthroughGuard.professionalAudioBundleIDs.contains(must))
        }
    }

    // MARK: - FakeMixer（通道增删与幂等）

    @Test func fakeMixerTracksChannelLifecycle() async {
        let mixer = FakeMixer()
        #expect(mixer.channels().isEmpty)
        mixer.addChannel(PerAppChannel(bundleID: "com.apple.Safari", displayName: "Safari", gainPercent: 70))
        mixer.addChannel(PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 50))
        // 快照按 bundleID 排序：确定性供预览与断言
        #expect(mixer.channels().map(\.bundleID) == ["com.apple.Safari", "com.spotify.client"])
        // App 退出：通道消失，增益下发随之失败（驱动侧无从施加）
        #expect(mixer.removeChannel(bundleID: "com.spotify.client"))
        #expect(mixer.channels().map(\.bundleID) == ["com.apple.Safari"])
        #expect(!(await mixer.setGain(bundleID: "com.spotify.client", gainPercent: 30)))
        #expect(!mixer.removeChannel(bundleID: "com.spotify.client"))  // 重复移除返回 false
    }

    @Test func fakeMixerSetGainIsIdempotent() async {
        let mixer = FakeMixer(channels: [
            PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 50),
        ])
        // 与当前值相同的下发：成功但不产生驱动写
        #expect(await mixer.setGain(bundleID: "com.spotify.client", gainPercent: 50))
        #expect(mixer.writeCount(for: "com.spotify.client") == 0)
        // 同值重复下发两次：只有第一次真正写
        #expect(await mixer.setGain(bundleID: "com.spotify.client", gainPercent: 80))
        #expect(await mixer.setGain(bundleID: "com.spotify.client", gainPercent: 80))
        #expect(mixer.writeCount(for: "com.spotify.client") == 1)
        // 值变了才再写
        #expect(await mixer.setGain(bundleID: "com.spotify.client", gainPercent: 40))
        #expect(mixer.writeCount(for: "com.spotify.client") == 2)
        #expect(mixer.channels() == [
            PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 40)
        ])
    }

    @Test func fakeMixerClampsAndRejectsUnknownBundle() async {
        let mixer = FakeMixer(channels: [
            PerAppChannel(bundleID: "x.y.z", displayName: "Z", gainPercent: 10),
        ])
        #expect(await mixer.setGain(bundleID: "x.y.z", gainPercent: 250))
        #expect(mixer.channels().first?.gainPercent == 100)
        #expect(await mixer.setGain(bundleID: "x.y.z", gainPercent: -30))
        #expect(mixer.channels().first?.gainPercent == 0)
        #expect(!(await mixer.setGain(bundleID: "no.such.app", gainPercent: 50)))
    }

    // MARK: - 面板模型

    @Test func mixerPanelModelComposesRulesAndDriverState() {
        let model = MixerPanelModel(
            channels: [
                PerAppChannel(bundleID: "com.spotify.client", displayName: "Spotify", gainPercent: 90),
                PerAppChannel(bundleID: "com.apple.Safari", displayName: "Safari", gainPercent: 90),
            ],
            rules: [PerAppRule(match: "spotify", maxGain: 40)],
            driverState: .installed)
        #expect(model.isFeatureAvailable)
        #expect(model.effectiveGains["com.spotify.client"] == 40)
        #expect(model.effectiveGains["com.apple.Safari"] == 90)
        // 未装驱动：入口整体隐藏（PAV-05），增益表算得出也不可消费
        let undriven = MixerPanelModel(channels: model.channels, rules: model.rules, driverState: .notInstalled)
        #expect(!undriven.isFeatureAvailable)
    }

    // MARK: - 持久化

    @Test func codableRoundTripsPreserveSemantics() throws {
        let channel = PerAppChannel(
            bundleID: "com.x.y", displayName: "X",
            gainPercent: 130, isMuted: true, ruleCap: 60)
        // 钳制发生在构造：编码前已是合法值
        #expect(channel.gainPercent == 100)
        let data = try JSONEncoder().encode(channel)
        #expect(try JSONDecoder().decode(PerAppChannel.self, from: data) == channel)

        let rule = PerAppRule(match: "Spotify", maxGain: 40, rememberPerApp: true, boostWhenFocused: true)
        let ruleData = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(PerAppRule.self, from: ruleData) == rule)
    }
}
