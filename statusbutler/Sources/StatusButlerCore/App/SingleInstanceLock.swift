import AppKit

// 单实例锁（A2·S2 / A14 审计三·壳项）：同 Bundle ID 只允许一个常驻实例。
// 走 NSRunningApplication 既存检查而非文件锁：进程表即真相，无残留锁文件的清理问题；
// 判定纯函数化（测试注入假运行列表），AppKit 副作用（激活/终止）收敛在 AppDelegate 接线层。

public enum SingleInstanceLock {

    /// 运行中 App 的最小快照：判定的全部输入（测试喂假数据，不碰 NSRunningApplication）
    public struct RunningApp: Equatable, Sendable {
        public let processIdentifier: Int32
        public let bundleIdentifier: String?

        public init(processIdentifier: Int32, bundleIdentifier: String?) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
        }

        /// 当前进程快照（AppKit 读取点唯一化，判定层不重复取系统态）
        @MainActor
        public static func current() -> RunningApp {
            let app = NSRunningApplication.current
            return RunningApp(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }

    /// 既存实例判定：同 Bundle ID 且 PID 不同。
    /// 宿主无 Bundle ID（swift test / 裸可执行）一律判无——宁可漏拦不可误杀（fail-open）：
    /// 误杀的代价是每次启动闪退，漏拦的代价只是两个实例并存
    public static func existingInstance(of own: RunningApp, in apps: [RunningApp]) -> RunningApp? {
        guard let bundleID = own.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        return apps.first {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != own.processIdentifier
        }
    }

    /// 启动接线：发现既存实例即激活它并返回 true——调用方（AppDelegate）据此立即终止本进程
    @MainActor
    @discardableResult
    public static func activateExistingInstanceIfPresent() -> Bool {
        let own = RunningApp.current()
        let runningApps = NSWorkspace.shared.runningApplications.map {
            RunningApp(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
        }
        guard let existing = existingInstance(of: own, in: runningApps) else { return false }
        // activate 返回值不保证（目标可能拒绝）；激活失败也优于两个实例互抢菜单栏
        NSRunningApplication(processIdentifier: existing.processIdentifier)?
            .activate(options: [.activateAllWindows])
        return true
    }
}
