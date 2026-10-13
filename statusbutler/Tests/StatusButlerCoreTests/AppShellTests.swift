import Testing
import Foundation
import ServiceManagement
@testable import StatusButlerCore

// T-058（A14 审计三·壳项）：单实例判定 / Dock 点击决策 / Dock 区域几何 / 登录项映射与接线。
// 全部走纯函数或协议注入假实现——不碰 NSWorkspace / SMAppService / NSScreen 真运行时。

// MARK: - 单实例锁

@Suite struct SingleInstanceLockTests {
    private let own = SingleInstanceLock.RunningApp(
        processIdentifier: 100, bundleIdentifier: "com.linzhongyang.statusbutler"
    )

    @Test func detectsRunningInstanceWithSameBundleID() {
        let other = SingleInstanceLock.RunningApp(
            processIdentifier: 200, bundleIdentifier: "com.linzhongyang.statusbutler"
        )
        #expect(SingleInstanceLock.existingInstance(of: own, in: [own, other]) == other)
    }

    @Test func ignoresSelfEntryAndOtherBundleIDs() {
        #expect(SingleInstanceLock.existingInstance(of: own, in: [own]) == nil)
        let different = SingleInstanceLock.RunningApp(
            processIdentifier: 300, bundleIdentifier: "com.other.app"
        )
        #expect(SingleInstanceLock.existingInstance(of: own, in: [own, different]) == nil)
        #expect(SingleInstanceLock.existingInstance(of: own, in: []) == nil)
    }

    @Test func hostWithoutBundleIDFailsOpen() {
        // swift test / 裸进程宿主无 Bundle ID：宁可漏拦不可误杀——误杀=每次启动闪退
        let bare = SingleInstanceLock.RunningApp(processIdentifier: 1, bundleIdentifier: nil)
        let otherBare = SingleInstanceLock.RunningApp(processIdentifier: 2, bundleIdentifier: nil)
        #expect(SingleInstanceLock.existingInstance(of: bare, in: [otherBare]) == nil)
        let blank = SingleInstanceLock.RunningApp(processIdentifier: 1, bundleIdentifier: "  ")
        #expect(SingleInstanceLock.existingInstance(of: blank, in: [otherBare]) == nil)
    }

    @Test func picksFirstDuplicateWhenSeveral() {
        let a = SingleInstanceLock.RunningApp(
            processIdentifier: 200, bundleIdentifier: "com.linzhongyang.statusbutler"
        )
        let b = SingleInstanceLock.RunningApp(
            processIdentifier: 300, bundleIdentifier: "com.linzhongyang.statusbutler"
        )
        #expect(SingleInstanceLock.existingInstance(of: own, in: [b, a]) == b)
    }
}

// MARK: - Dock 点击决策表（A2·S2 四情形）

@Suite struct DockActivationActionTests {
    @Test func dockIconClickTogglesPopover() {
        #expect(
            DockActivationAction.resolve(
                isReopenEvent: true, hasDockTile: true, isPointerInDockArea: true
            ) == .showPopover
        )
    }

    @Test func dockAreaClickWithoutDockTileOpensSettings() {
        // menuBarOnly 无 Dock 图标（hasDockTile=false）：即便指针在 Dock 区域也不是本 App 的点击
        #expect(
            DockActivationAction.resolve(
                isReopenEvent: true, hasDockTile: false, isPointerInDockArea: true
            ) == .openSettings
        )
    }

    @Test func launchpadOrSpotlightReopenOpensSettings() {
        // Launchpad / Finder / Spotlight 发同一 reopen 事件——指针位置是唯一区分信号
        #expect(
            DockActivationAction.resolve(
                isReopenEvent: true, hasDockTile: true, isPointerInDockArea: false
            ) == .openSettings
        )
    }

    @Test func coldLaunchPathDoesNothing() {
        // 冷启动（含登录项拉起）在部分路径也到 shouldHandleReopen——一律不弹
        #expect(
            DockActivationAction.resolve(
                isReopenEvent: false, hasDockTile: true, isPointerInDockArea: true
            ) == .none
        )
        #expect(
            DockActivationAction.resolve(
                isReopenEvent: false, hasDockTile: false, isPointerInDockArea: false
            ) == .none
        )
    }
}

// MARK: - Dock 区域几何（纯 NSRect 数学）

@Suite struct DockPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func resolveInfersOrientationFromFrameGap() {
        // Dock 是唯一能横向压缩 visibleFrame 的常驻物（菜单栏只压顶部）
        #expect(
            DockPlacement.resolve(
                screenFrame: screen, visibleFrame: NSRect(x: 0, y: 70, width: 1440, height: 805)
            ) == .bottom
        )
        #expect(
            DockPlacement.resolve(
                screenFrame: screen, visibleFrame: NSRect(x: 80, y: 0, width: 1360, height: 900)
            ) == .left
        )
        #expect(
            DockPlacement.resolve(
                screenFrame: screen, visibleFrame: NSRect(x: 0, y: 0, width: 1360, height: 900)
            ) == .right
        )
    }

    @Test func visibleDockStripContainsPointer() {
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)
        let bottom = DockPlacement.resolve(screenFrame: screen, visibleFrame: visible)
        #expect(bottom == .bottom)
        #expect(bottom.containsPointer(NSPoint(x: 720, y: 30), screenFrame: screen, visibleFrame: visible))
        #expect(!bottom.containsPointer(NSPoint(x: 720, y: 300), screenFrame: screen, visibleFrame: visible))
    }

    @Test func autoHiddenDockFallsBackToEdgeTolerance() {
        // 自动隐藏 Dock 时 visibleFrame 填满屏幕——边沿容差是唯一可用信号
        let full = screen
        let bottom = DockPlacement.resolve(screenFrame: screen, visibleFrame: full)
        #expect(bottom == .bottom)
        #expect(bottom.containsPointer(NSPoint(x: 720, y: 40), screenFrame: screen, visibleFrame: full))
        #expect(!bottom.containsPointer(NSPoint(x: 720, y: 200), screenFrame: screen, visibleFrame: full))
    }

    @Test func sideDocksContainAlongTheirEdge() {
        let leftVisible = NSRect(x: 80, y: 0, width: 1360, height: 900)
        let left = DockPlacement.resolve(screenFrame: screen, visibleFrame: leftVisible)
        #expect(left == .left)
        #expect(left.containsPointer(NSPoint(x: 40, y: 450), screenFrame: screen, visibleFrame: leftVisible))
        #expect(!left.containsPointer(NSPoint(x: 400, y: 450), screenFrame: screen, visibleFrame: leftVisible))

        let rightVisible = NSRect(x: 0, y: 0, width: 1360, height: 900)
        let right = DockPlacement.resolve(screenFrame: screen, visibleFrame: rightVisible)
        #expect(right == .right)
        #expect(right.containsPointer(NSPoint(x: 1400, y: 450), screenFrame: screen, visibleFrame: rightVisible))
        #expect(!right.containsPointer(NSPoint(x: 1000, y: 450), screenFrame: screen, visibleFrame: rightVisible))
    }
}

// MARK: - 登录项

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var stubSupported = true
    var stubStatus: LaunchAtLoginStatus = .notRegistered
    private(set) var registeredCalls: [Bool] = []
    private(set) var openSettingsCalls = 0

    var isSupported: Bool { stubSupported }
    var status: LaunchAtLoginStatus { stubStatus }

    func setRegistered(_ registered: Bool) {
        registeredCalls.append(registered)
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}

@MainActor
@Suite struct LaunchAtLoginTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func mapsSMAppServiceStatusToThreeStates() {
        #expect(LaunchAtLoginStatus.from(.enabled) == .enabled)
        #expect(LaunchAtLoginStatus.from(.requiresApproval) == .requiresApproval)
        // 未注册/从未找到同义（不同 macOS 版本回报其一），注册动作从两态出发都合法
        #expect(LaunchAtLoginStatus.from(.notRegistered) == .notRegistered)
        #expect(LaunchAtLoginStatus.from(.notFound) == .notRegistered)
    }

    @Test func requiresApprovalCountsAsOn() {
        // 开关口径：待批准算"开"——回显用户要求过的状态，不静默回跳成关
        #expect(LaunchAtLoginStatus.enabled.isOn)
        #expect(LaunchAtLoginStatus.requiresApproval.isOn)
        #expect(!LaunchAtLoginStatus.notRegistered.isOn)
    }

    @Test func storeTogglesDriveRegisterAndUnregister() {
        let service = FakeLoginItemService()
        let store = SettingsStore(defaults: makeDefaults(), loginItem: service)
        store.launchAtLogin = true
        store.launchAtLogin = false
        #expect(service.registeredCalls == [true, false])
        // 偏好同步落盘：无服务宿主（测试/CLI）重载仍可读
        let reloaded = SettingsStore(defaults: makeDefaults(), loginItem: nil)
        #expect(reloaded.launchAtLogin == false)
    }

    @Test func initialValueFollowsSystemRegistration() {
        let service = FakeLoginItemService()
        service.stubStatus = .enabled
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults, loginItem: service)
        #expect(store.launchAtLogin)

        // 系统注册态被移除（用户手动删登录项）→ 初值诚实回落为关，不显示存储里的旧偏好
        service.stubStatus = .notRegistered
        let reloaded = SettingsStore(defaults: defaults, loginItem: service)
        #expect(!reloaded.launchAtLogin)

        // 无服务宿主（isLoginItemSupported=false）回落持久化值
        let bareStore = SettingsStore(defaults: defaults, loginItem: nil)
        #expect(bareStore.loginItemStatus == .notRegistered)
        #expect(!bareStore.isLoginItemSupported)
    }

    @Test func requiresApprovalSurfacesThroughStoreStatus() {
        let service = FakeLoginItemService()
        service.stubStatus = .requiresApproval
        let store = SettingsStore(defaults: makeDefaults(), loginItem: service)
        #expect(store.loginItemStatus == .requiresApproval)
        #expect(store.isLoginItemSupported)
        store.openLoginItemsSettings()
        #expect(service.openSettingsCalls == 1)
    }
}
