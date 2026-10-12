import Foundation
import Carbon.HIToolbox
import Testing

@testable import StatusButlerCore

// T-051: 熄屏会话状态机 / 断言句柄安全 / 守护决策表 / 热键编码与注册生命周期
@Suite struct ScreenHotKeyTests {

    // MARK: - SCR-02 守护决策表（纯）

    @Test func shouldKeepAwakeDecisionTableIsExhaustive() {
        let session = ScreenOffSession()
        #expect(session.shouldKeepAwake(downloadActive: true, cpuBusy: true))
        #expect(session.shouldKeepAwake(downloadActive: true, cpuBusy: false))
        #expect(session.shouldKeepAwake(downloadActive: false, cpuBusy: true))
        #expect(!session.shouldKeepAwake(downloadActive: false, cpuBusy: false))
    }

    // MARK: - 断言句柄 nil 安全（纯状态机）

    @Test func sessionHandleIsNilSafeAndEndIsIdempotent() {
        var session = ScreenOffSession()
        #expect(session.assertionID == 0)
        #expect(!session.isProtected)
        session.end()
        session.end()  // 幂等
        #expect(session.assertionID == 0)
        #expect(!session.isProtected)

        var held = ScreenOffSession(assertionID: 77)
        #expect(held.isProtected)
        held.end()
        #expect(!held.isProtected)

        #expect(ScreenOffSession(assertionID: 0) == ScreenOffSession())
    }

    // MARK: - live 断言生命周期（幂等；CI 拒绝创建时容忍 nil）

    @Test func idleSleepAssertionLifecycleIsIdempotentAndCrashSafe() {
        let controller = ScreenController()
        if let session = controller.holdIdleSleepAssertion() {
            #expect(session.isProtected)
            // 二次持有幂等：返回同一句柄，不叠加创建
            #expect(controller.holdIdleSleepAssertion() == session)
        }
        #expect(controller.releaseIdleSleepAssertion())
        #expect(controller.releaseIdleSleepAssertion())  // 幂等 + 句柄 0 安全
        #expect(!controller.session().isProtected)
    }

    @Test func sleepDisplaysNowDegradesWithoutCrashing() {
        // displaysleepnow 是白名单只读信号命令；本机（含沙盒）应成功，
        // 极端环境（可执行缺失）返回 false——两种结局都不允许崩
        _ = ScreenController().sleepDisplaysNow()
    }

    // MARK: - 热键组合编码（纯）

    @Test func modifierEncodingComposesCarbonFlags() {
        #expect(HotKeyCombo.encodeModifiers() == 0)
        #expect(HotKeyCombo.encodeModifiers(command: true) == UInt32(cmdKey))
        #expect(HotKeyCombo.encodeModifiers(option: true) == UInt32(optionKey))
        #expect(HotKeyCombo.encodeModifiers(shift: true) == UInt32(shiftKey))
        #expect(HotKeyCombo.encodeModifiers(control: true) == UInt32(controlKey))
        #expect(HotKeyCombo.encodeModifiers(command: true, shift: true) == UInt32(cmdKey | shiftKey))
        #expect(HotKeyCombo.encodeModifiers(command: true, option: true, shift: true, control: true)
                == UInt32(cmdKey | optionKey | shiftKey | controlKey))
    }

    @Test func hotKeyComboEqualityCoversKeyCodeAndModifiers() {
        let cmdOpt = HotKeyCombo.encodeModifiers(command: true, option: true)
        #expect(HotKeyCombo(keyCode: 0x2F, modifiers: cmdOpt)
                == HotKeyCombo(keyCode: 0x2F, modifiers: cmdOpt))
        #expect(HotKeyCombo(keyCode: 0x2F, modifiers: 0x100)
                != HotKeyCombo(keyCode: 0x2E, modifiers: 0x100))  // 键码不同
        #expect(HotKeyCombo(keyCode: 0x2F, modifiers: 0x100)
                != HotKeyCombo(keyCode: 0x2F, modifiers: 0x200))  // 修饰不同
        // 布尔构造与掩码构造等值（录制器 ⇄ 持久化两侧一致）
        #expect(HotKeyCombo(keyCode: 1, command: true)
                == HotKeyCombo(keyCode: 1, modifiers: UInt32(cmdKey)))
    }

    // MARK: - 注册生命周期（@MainActor；无 WindowServer 的 CI 拒绝注册 → 容忍 false）

    @Test @MainActor func hotKeyRegistrationLifecycleIsIdempotent() {
        let center = HotKeyCenter()  // 独立实例，不污染 shared
        let combo = HotKeyCombo(keyCode: 0x2F, modifiers: HotKeyCombo.encodeModifiers(command: true, option: true))
        let registered = center.register(id: 7, combo: combo) {}

        if registered {
            #expect(center.registeredCount == 1)
            // 同 id 不重复注册
            #expect(!center.register(id: 7, combo: HotKeyCombo(keyCode: 0x30)) {})
            // 第二个 id 正常注册/注销
            #expect(center.register(id: 8, combo: HotKeyCombo(keyCode: 0x31, modifiers: UInt32(cmdKey))) {})
            center.unregister(id: 8)
        }
        center.unregister(id: 7)
        center.unregister(id: 7)  // 幂等
        #expect(center.registeredCount == 0)
    }

    @Test @MainActor func unregisterAllClearsEverything() {
        let center = HotKeyCenter()
        let combo1 = HotKeyCombo(keyCode: 0x19, modifiers: UInt32(cmdKey))
        let combo2 = HotKeyCombo(keyCode: 0x1A, modifiers: UInt32(optionKey))
        let firstRegistered = center.register(id: 1, combo: combo1) {}
        center.register(id: 2, combo: combo2) {}
        center.unregisterAll()
        #expect(center.registeredCount == 0)
        if firstRegistered {
            // 清空后可重新注册同一 id
            #expect(center.register(id: 1, combo: combo1) {})
        }
    }
}
