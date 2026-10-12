import Foundation
import os

// MARK: - 驱动桥接（T-050 · A11 E20 PAV-01/PAV-05）
// 真实现 = T-050b 的 AudioDriverKit 接线（XPC 到系统扩展，把规则引擎输出的目标增益表
// 下发到虚拟设备混音器，并把"哪些 App 在发声/退出"事件回传）。协议注入让用户态半场
// 不依赖驱动即可编译、测试、出预览（PAV-05 驱动可摘除；不装驱动功能整体隐藏）。

/// 混音桥接：读当前通道快照 / 下发单 App 目标增益。
public protocol PerAppMixing: Sendable {
    /// 正在发声的 App 快照（真实现由驱动事件维护缓存，读路径零阻塞；App 退出通道即消失）。
    func channels() -> [PerAppChannel]
    /// 下发目标增益（0-100，越界由实现钳制）。未知 App 或驱动未就绪返回 false。
    /// 幂等：同值重复下发不应产生额外驱动写（真实现按此节流，FakeMixer 同语义）。
    func setGain(bundleID: String, gainPercent: Int) async -> Bool
}

// MARK: - FakeMixer（测试/SwiftUI 预览注入）
/// 假混音器：内存态通道表 + 驱动写计数。写计数只在值真正变化时递增，
/// 用来断言"同值重复下发不写驱动"的幂等约定。
public final class FakeMixer: PerAppMixing {
    private struct Store {
        var channels: [String: PerAppChannel] = [:]
        var writeCounts: [String: Int] = [:]
    }

    /// 锁自身 Sendable、State 全值类型：整类即可安全跨并发域，无需 @unchecked。
    private let store = OSAllocatedUnfairLock(initialState: Store())

    public init(channels: [PerAppChannel] = []) {
        let initial = channels.reduce(into: [String: PerAppChannel]()) { $0[$1.bundleID] = $1 }
        store.withLock { $0.channels = initial }
    }

    public func channels() -> [PerAppChannel] {
        // 按 bundleID 排序保证快照确定性（预览与测试断言不抖动）
        store.withLock { $0.channels.values.sorted { $0.bundleID < $1.bundleID } }
    }

    public func setGain(bundleID: String, gainPercent: Int) async -> Bool {
        store.withLock { store in
            guard var channel = store.channels[bundleID] else { return false }
            let clamped = PerAppChannel.clamp(gainPercent)
            // 幂等：目标值未变不重复写（模拟驱动写节流，对齐 FanControlEngine 的写纪律）
            guard channel.gainPercent != clamped else { return true }
            channel.gainPercent = clamped
            store.channels[bundleID] = channel
            store.writeCounts[bundleID, default: 0] += 1
            return true
        }
    }

    // MARK: 测试脚手架（模拟驱动事件：App 开始发声 / 退出）

    /// 模拟 App 开始发声。真实现由驱动聚合 CoreAudio 事件驱动，本方法只为测试/预览。
    public func addChannel(_ channel: PerAppChannel) {
        store.withLock { $0.channels[channel.bundleID] = channel }
    }

    /// 模拟 App 退出：通道消失，之后对该 App 的 setGain 返回 false（驱动侧无从施加）。
    @discardableResult
    public func removeChannel(bundleID: String) -> Bool {
        store.withLock { store in
            let existed = store.channels.removeValue(forKey: bundleID) != nil
            store.writeCounts.removeValue(forKey: bundleID)
            return existed
        }
    }

    /// 该 App 的实际驱动写次数（仅值变化才 +1；幂等断言用）。
    public func writeCount(for bundleID: String) -> Int {
        store.withLock { $0.writeCounts[bundleID] ?? 0 }
    }
}

// MARK: - 面板模型（设置页/弹层下钻页共用的纯快照）
/// 混音台面板状态：通道 + 规则 + 驱动状态。值类型供 SwiftUI 直接消费；
/// 不持有桥接对象——写路径由上层 ViewModel 经 PerAppMixing 走，依赖保持单向。
public struct MixerPanelModel: Sendable, Equatable {
    public var channels: [PerAppChannel]
    public var rules: [PerAppRule]
    public var driverState: DriverInstallState

    public init(
        channels: [PerAppChannel] = [],
        rules: [PerAppRule] = [],
        driverState: DriverInstallState = .notInstalled
    ) {
        self.channels = channels
        self.rules = rules
        self.driverState = driverState
    }

    /// PAV-05：未装驱动时功能整体隐藏——入口显隐只看这一位。
    public var isFeatureAvailable: Bool { driverState.isDriverReady }

    /// 目标增益表（不含焦点态：面板快照是静态投影，焦点抬升由持有焦点订阅的上层
    /// 带 focusedBundleID 调 PerAppRuleEngine.applyRules 重算）。
    public var effectiveGains: [String: Int] {
        PerAppRuleEngine.applyRules(channels: channels, rules: rules)
    }
}
