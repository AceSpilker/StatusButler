import AppKit
import Foundation

// MARK: - 音量写通道（A14-β：滑杆可写 + 行内滚轮调节）

public protocol VolumeWriting: Sendable {
    /// level 已由调用方钳制到 0...100
    func write(level: Int) async
}

/// AppleScript `set volume` 是公开的音量落点（无需辅助功能授权）——与 App/AutomationCoordinator
/// 同一公开手法，但按依赖单向铁律在 Panel 域独立成文（App 装配 → UI，不反向取用）。
/// 执行折进 detached 任务：AppleScript 往返可达百毫秒级，不占主线程
public struct AppleScriptVolumeWriter: VolumeWriting {
    public init() {}

    public func write(level: Int) async {
        let source = VolumeScript.outputVolumeScript(for: level)
        // 闭包显式返回 Void：执行结果 NSAppleEventDescriptor 非 Sendable，不跨任务边界携带
        await Task.detached(priority: .userInitiated) { () -> Void in
            _ = NSAppleScript(source: source)?.executeAndReturnError(nil)
        }.value
    }
}

/// AppleScript 源串纯生成器（单测钉死串面，绝不执行）
public enum VolumeScript {
    public static func clamp(_ level: Int) -> Int { min(max(level, 0), 100) }

    public static func outputVolumeScript(for level: Int) -> String {
        "set volume output volume \(clamp(level))"
    }

    public static var toggleMuteScript: String { "set volume output muted (not (output muted))" }
}

// MARK: - 写节流（纯决策）

/// 滑杆拖动/滚轮是事件洪流，直写会每帧起一次 AppleScript。节流策略：窗口外（含首写）立即写；
/// 窗口内只记尾随值，到点冲刷一次末值——中间值全部丢弃（音量只关心终点，不需要过程回放）
public struct VolumeWriteDecision: Equatable, Sendable {
    public let writeNow: Bool
    /// 非立即写时距冲刷点的剩余秒数（= 距上次写入的补足量）
    public let flushAfter: TimeInterval?

    public init(writeNow: Bool, flushAfter: TimeInterval?) {
        self.writeNow = writeNow
        self.flushAfter = flushAfter
    }
}

public enum VolumeThrottle {
    public static func decide(lastWriteAt: Date?, now: Date, minInterval: TimeInterval) -> VolumeWriteDecision {
        guard let lastWriteAt else { return VolumeWriteDecision(writeNow: true, flushAfter: nil) }
        let elapsed = now.timeIntervalSince(lastWriteAt)
        if elapsed >= minInterval {
            return VolumeWriteDecision(writeNow: true, flushAfter: nil)
        }
        return VolumeWriteDecision(writeNow: false, flushAfter: minInterval - elapsed)
    }
}

// MARK: - 滚轮方向与步进（纯决策）

/// 音量行内滚轮调节的方向决策。AppKit 惯例 scrollingDeltaY > 0 = "向上滚动"。
/// - 自然滚动开（默认，与系统默认一致）：上翻增值的 iOS 选择器同感——deltaY < 0（手指上扫）调大；
/// - 传统滚动：滚轮上滚（deltaY > 0）调大——滚轮+滑杆的经典映射。
/// 方向手感是"为什么"级决策：两种系统设置下同一手势应给出相反结果，纯函数钉死决策表
public enum ScrollVolumeMapping {
    public static let defaultStep = 2

    public static func volumeDelta(scrollDeltaY: Double, naturalScrolling: Bool, step: Int = defaultStep) -> Int {
        guard scrollDeltaY != 0 else { return 0 }
        let magnitude = max(step, 1)
        let increase = naturalScrolling ? scrollDeltaY < 0 : scrollDeltaY > 0
        return increase ? magnitude : -magnitude
    }

    public static func apply(delta: Int, toLevel level: Int) -> Int {
        min(max(level + delta, 0), 100)
    }
}

// MARK: - 乐观显示（纯决策）

/// 写路径开启后面板显示"乐观值"（写出去的档位）而非等 500ms 防抖快照追平；
/// 快照追平或弹层关闭时清除。resolve 是纯函数，单测钉死降级链
public enum VolumeDisplay {
    public static func resolve(snapshot: VolumeState, override: Int?) -> VolumeState {
        guard let override else { return snapshot }
        return VolumeState(level: min(max(override, 0), 100), isMuted: snapshot.isMuted)
    }
}
