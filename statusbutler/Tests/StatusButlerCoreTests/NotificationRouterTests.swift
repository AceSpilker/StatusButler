import Foundation
import Testing
import UserNotifications

@testable import StatusButlerCore

// T-215 通知系统（E11·TF-30 / E13 / E18）：规则形态、授权流、频率限制矩阵
// （冷却窗口内不发 / 窗口外发 / 不同规则独立冷却 / 持续时长 / 缺测不累计）。
// UNUserNotificationCenter 被隔离在 SystemUserNotifier 里，测试全部走假投递器——
// CI 进程不碰通知中心真身（无 bundle 的进程里其行为未定义）。
@MainActor
@Suite(.serialized)
struct NotificationRouterTests {

    // MARK: - 假投递器

    /// 记录投递与授权行为的假件（锁纪律：deliveries 仅在锁内读写）
    final class FakeUserNotifier: UserNotifying, @unchecked Sendable {
        private let lock = NSLock()
        private let grants: Bool
        private let status: UNAuthorizationStatus
        private var deliveriesValue: [(title: String, body: String)] = []

        init(grants: Bool = true, status: UNAuthorizationStatus = .authorized) {
            self.grants = grants
            self.status = status
        }

        var deliveries: [(title: String, body: String)] {
            lock.withLock { deliveriesValue }
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            lock.withLock { status }
        }

        func requestAuthorization() async -> Bool {
            lock.withLock { grants }
        }

        func deliver(title: String, body: String) async {
            lock.withLock { deliveriesValue.append((title, body)) }
        }
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRouter(
        _ rules: [AlertRule],
        notifier: FakeUserNotifier = FakeUserNotifier()
    ) -> NotificationRouter {
        NotificationRouter(rules: rules, notifier: notifier)
    }

    // MARK: - 规则形态（三规则钉死阈值/时长/冷却）

    @Test func standardRulesShape() {
        #expect(AlertRules.all.count == 3)
        #expect(Set(AlertRules.all.map(\.id)).count == 3)
        #expect(AlertRules.temperatureHigh.threshold == 90)
        #expect(AlertRules.temperatureHigh.sustain == 60)
        #expect(AlertRules.batteryLow.threshold == 20)
        #expect(AlertRules.batteryLow.sustain == 0)
        #expect(AlertRules.healthPoor.threshold == 60)
        #expect(AlertRules.healthPoor.cooldown == 7 * 24 * 3600)  // 每周一次
        #expect(AlertRules.all.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
    }

    // MARK: - 授权流

    @Test func authorizationFlowPassesThroughInjectedNotifier() async {
        let granted = makeRouter([AlertRules.batteryLow], notifier: FakeUserNotifier(grants: true))
        let result = await granted.requestAuthorization()
        #expect(result)
        #expect(granted.isAuthorized == true)

        let denied = makeRouter([AlertRules.batteryLow], notifier: FakeUserNotifier(grants: false))
        #expect(await denied.requestAuthorization() == false)  // 被拒如实反馈，不伪装
        #expect(denied.isAuthorized == false)

        // 无投递面（设置全关的形态）：授权恒 false（不需要授权也就不假装有）
        let bare = NotificationRouter(rules: [AlertRules.batteryLow], notifier: nil)
        #expect(await bare.requestAuthorization() == false)
    }

    // MARK: - 温度规则：持续 60s + 冷却 10 分钟

    @Test func temperatureRuleRequiresSustainThenCooldown() async {
        let notifier = FakeUserNotifier()
        let router = makeRouter([AlertRules.temperatureHigh], notifier: notifier)
        let hot = AlertSample(maxCelsius: 92, batteryPercent: 80, healthScore: 90)

        // 首见记时刻，sustain 未满不发
        #expect(await router.process(hot, now: base) == [])
        // +59s：仍差 1 秒
        #expect(await router.process(hot, now: base.addingTimeInterval(59)) == [])
        // +60s：满持续时长 → 发（TF-30：>90°C 持续 60s）
        #expect(await router.process(hot, now: base.addingTimeInterval(60)) == ["temperatureHigh"])
        #expect(notifier.deliveries.count == 1)
        #expect(notifier.deliveries.first?.title == "温度警报")

        // 冷却窗口（600s）内再次满条件：不发
        #expect(await router.process(hot, now: base.addingTimeInterval(659)) == [])
        // 窗口边界（距上次通知整 600s）：放行
        #expect(await router.process(hot, now: base.addingTimeInterval(660)) == ["temperatureHigh"])
        #expect(notifier.deliveries.count == 2)
        // 冷却窗口外远期重复：仍按冷却节奏（+600 再发一次）
        #expect(await router.process(hot, now: base.addingTimeInterval(2000)) == ["temperatureHigh"])
        #expect(notifier.deliveries.count == 3)
    }

    // MARK: - 电池规则：sustain 0 即触发 + 冷却 30 分钟

    @Test func batteryRuleFiresImmediatelyAndCooldownSuppresses() async {
        let notifier = FakeUserNotifier()
        let router = makeRouter([AlertRules.batteryLow], notifier: notifier)
        let low = AlertSample(maxCelsius: 50, batteryPercent: 15, healthScore: 90)

        #expect(await router.process(low, now: base) == ["batteryLow"])  // 首见即发
        #expect(await router.process(low, now: base.addingTimeInterval(100)) == [])  // 冷却内
        #expect(await router.process(low, now: base.addingTimeInterval(1799)) == [])
        #expect(await router.process(low, now: base.addingTimeInterval(1800)) == ["batteryLow"])  // 边界放行
        #expect(notifier.deliveries.count == 2)

        // 条件中断后恢复：sustain 从零重计（0s 规则即时），但冷却仍从上次通知算
        let fine = AlertSample(maxCelsius: 50, batteryPercent: 50, healthScore: 90)
        #expect(await router.process(fine, now: base.addingTimeInterval(2000)) == [])
        #expect(await router.process(low, now: base.addingTimeInterval(2100)) == [])  // 冷却未满（距 1800 仅 300s）
        #expect(await router.process(low, now: base.addingTimeInterval(3600)) == ["batteryLow"])
    }

    // MARK: - 不同规则独立冷却

    @Test func cooldownsAreIndependentPerRule() async {
        let notifier = FakeUserNotifier()
        let router = makeRouter([AlertRules.batteryLow, AlertRules.healthPoor], notifier: notifier)

        // 只低电：healthPoor 域缺测不参与判定
        #expect(await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 15, healthScore: nil), now: base
        ) == ["batteryLow"])
        // +10s：电池在冷却内不发；体检分新越阈——独立状态，照发（每周一次规则首见即发）
        #expect(await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 15, healthScore: 55),
            now: base.addingTimeInterval(10)
        ) == ["healthPoor"])
        // 投递内容按规则各自携带 title/body
        #expect(notifier.deliveries.map { $0.title } == ["电池电量低", "体检提醒"])
        // 一周内体检持续低分：不再发（每周一次）
        #expect(await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 50, healthScore: 55),
            now: base.addingTimeInterval(6 * 24 * 3600)
        ) == [])
        // 距上次体检通知满 7 天（10s 偏移对齐：首发在 base+10）→ 再发
        #expect(await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 50, healthScore: 55),
            now: base.addingTimeInterval(7 * 24 * 3600 + 10)
        ) == ["healthPoor"])
    }

    // MARK: - 缺测不累计 sustain（温度中断重计）

    @Test func missingMetricResetsSustainWindow() async {
        let notifier = FakeUserNotifier()
        let router = makeRouter([AlertRules.temperatureHigh], notifier: notifier)

        #expect(await router.process(AlertSample(maxCelsius: 92), now: base) == [])
        // 30s 时缺测（传感器读失败）：条件中断，已累计的 30s 作废
        #expect(await router.process(AlertSample(maxCelsius: nil), now: base.addingTimeInterval(30)) == [])
        // 重新越阈：从 40s 起重计，99s（59s 后）不满 60s
        #expect(await router.process(AlertSample(maxCelsius: 95), now: base.addingTimeInterval(40)) == [])
        #expect(await router.process(AlertSample(maxCelsius: 95), now: base.addingTimeInterval(99)) == [])
        // 100s（满 60s）→ 发
        #expect(await router.process(AlertSample(maxCelsius: 95), now: base.addingTimeInterval(100)) == ["temperatureHigh"])
    }

    // MARK: - 授权被拒：判定照常、投递抑制

    @Test func deniedAuthorizationSuppressesDeliveryButDecisionContinues() async {
        let notifier = FakeUserNotifier(grants: false, status: .denied)
        let router = makeRouter([AlertRules.batteryLow], notifier: notifier)

        #expect(await router.requestAuthorization() == false)
        let fired = await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 15), now: base
        )
        #expect(fired == ["batteryLow"])  // 判定与状态机照常（授权恢复后即恢复投递）
        #expect(notifier.deliveries.isEmpty)  // 但实际投递被抑制
        #expect(router.lastFiredRuleIDs == ["batteryLow"])
        // 冷却照常生效：被拒期间的"发"也占一次窗口（恢复后不会补发刷屏）
        #expect(await router.process(
            AlertSample(maxCelsius: nil, batteryPercent: 15),
            now: base.addingTimeInterval(100)
        ) == [])
    }

    // MARK: - 边界：阈值口径

    @Test func thresholdBoundariesFollowSpec() {
        // 温度 >90 才越阈（91 越、90 不越——"超过 90°C"的字面口径）
        #expect(AlertRateLimiter.isViolating(
            AlertRules.temperatureHigh, sample: AlertSample(maxCelsius: 90)
        ) == false)
        #expect(AlertRateLimiter.isViolating(
            AlertRules.temperatureHigh, sample: AlertSample(maxCelsius: 90.5)
        ) == true)
        // 电量 <20（19 越、20 不越）；缺测 nil 不判定
        #expect(AlertRateLimiter.isViolating(
            AlertRules.batteryLow, sample: AlertSample(batteryPercent: 20)
        ) == false)
        #expect(AlertRateLimiter.isViolating(
            AlertRules.batteryLow, sample: AlertSample(batteryPercent: 19)
        ) == true)
        #expect(AlertRateLimiter.isViolating(
            AlertRules.batteryLow, sample: AlertSample(batteryPercent: nil)
        ) == nil)
        // 体检 <60（59 越、60 不越）
        #expect(AlertRateLimiter.isViolating(
            AlertRules.healthPoor, sample: AlertSample(healthScore: 60)
        ) == false)
        #expect(AlertRateLimiter.isViolating(
            AlertRules.healthPoor, sample: AlertSample(healthScore: 59)
        ) == true)
    }
}
