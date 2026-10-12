import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 一键熄屏不睡眠（T-051 · A11 E21 SCR-01~04）

/// 熄屏会话（值类型状态机）：assertionID 0 = 未持有——IOPMAssertionID 从不为 0，
/// 0 即"nil 句柄"，一切操作对其幂等安全（构造即空会话，永不强解包）。
/// 纯状态在本类型；IOKit/Process 副作用归 ScreenController。
public struct ScreenOffSession: Equatable, Sendable {
    public private(set) var assertionID: IOPMAssertionID

    public init(assertionID: IOPMAssertionID = 0) {
        self.assertionID = assertionID
    }

    /// SCR-03 徽标依据："屏幕已关 · 系统运行中"只在断言持有期间展示
    public var isProtected: Bool { assertionID != 0 }

    /// SCR-02 守护模式纯决策：活跃下载或 CPU 高负载任一为真 → 维持"熄屏不睡"断言
    ///（caffeinate -u 思路的产品化；两信号由监控层现有 NetRate/Cpu 监控器供给）
    public func shouldKeepAwake(downloadActive: Bool, cpuBusy: Bool) -> Bool {
        downloadActive || cpuBusy
    }

    /// 结束会话（纯迁移）：句柄清零幂等；真实 IOPMAssertionRelease 由控制器执行
    public mutating func end() {
        assertionID = 0
    }
}

/// 副作用侧：断言持有 + displaysleepnow。断言所有权在本实例（Sendable 经锁盒），
/// ScreenOffSession 只是下发给 UI 的值快照——重复持有/释放全部幂等收敛于此。
public final class ScreenController: Sendable {
    private let box = ScreenAssertionBox()

    public init() {}

    /// SCR-01：持有"阻止空闲入睡"断言（与 caffeinate 同机制，E21 技术结论：公开 API）。
    /// 崩溃安全：断言随进程消亡由 powerd 自动回收（SCR-03 "退出/崩溃不留后遗症"），
    /// 无需 atexit/信号处理兜底；本实例正常释放路径是 deinit → release。
    /// 幂等：已持有时直接返回同一句柄的会话，不叠加创建（断言引用计数不膨胀）。
    public func holdIdleSleepAssertion() -> ScreenOffSession? {
        box.hold().map { ScreenOffSession(assertionID: $0) }
    }

    /// 释放断言；幂等且句柄 0 安全（从未持有/会话已结束 → 直接成功）
    @discardableResult
    public func releaseIdleSleepAssertion() -> Bool {
        box.release()
    }

    /// 当前持有状态的值快照（UI 徽标 / 测试观察口）
    public func session() -> ScreenOffSession {
        ScreenOffSession(assertionID: box.currentID())
    }

    /// SCR-01：立即熄屏。白名单命令：绝对路径 + 固定动词、无 shell、零用户输入透传
    ///（A2·S12 最小攻击面，与 ButlerCommand 的动词白名单同纪律）。
    /// displaysleepnow 只向 WindowServer 发信号后立即退出，waitUntilExit 不构成可感知阻塞。
    @discardableResult
    public func sleepDisplaysNow() -> Bool {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
            pmset.waitUntilExit()
            return pmset.terminationStatus == 0
        } catch {
            return false  // 可执行缺失（极端裁剪系统）静默降级，不影响断言路径
        }
    }
}

/// 断言句柄盒：@unchecked Sendable 论证——heldAssertionID 只在 NSLock 内读写。
private final class ScreenAssertionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var heldAssertionID: IOPMAssertionID = 0

    func hold() -> IOPMAssertionID? {
        lock.lock()
        defer { lock.unlock() }
        if heldAssertionID != 0 { return heldAssertionID }
        var id = IOPMAssertionID(0)
        // 断言名带归属：pmset -g 断言清单里可辨识本 App（隐私/可诊断折中）
        let kr = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StatusButler 熄屏守护（E21 SCR）" as CFString,
            &id)
        guard kr == kIOReturnSuccess, id != 0 else { return nil }
        heldAssertionID = id
        return id
    }

    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard heldAssertionID != 0 else { return true }
        let kr = IOPMAssertionRelease(heldAssertionID)
        // 失败也清零：release 失败意味着句柄已失效（系统断言重置），重试无意义，
        // 宁可少持有一次也不留"以为在守护"的假状态
        heldAssertionID = 0
        return kr == kIOReturnSuccess
    }

    func currentID() -> IOPMAssertionID {
        lock.lock()
        defer { lock.unlock() }
        return heldAssertionID
    }

    deinit {
        // 正常路径兜底：实例死亡即释放；崩溃路径（deinit 不会跑）由 powerd 回收
        if heldAssertionID != 0 {
            IOPMAssertionRelease(heldAssertionID)
        }
    }
}
