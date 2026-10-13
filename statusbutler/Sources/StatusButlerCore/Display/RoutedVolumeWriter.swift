import AppKit
import Foundation

// T-202 组合音量写入器（A2·S6 / A11·E14）：弹层滑杆/滚轮/CLI 的音量落点不再恒走
// AppleScript，而是按 DDCRouting 判定路由——默认输出是外接屏（HDMI/DP 音频，
// macOS 音量对它恒满格）时写显示器 DDC 0x62，其余一切走系统音量。
//
// 协议形态说明（跨区只 conform 不改文件）：UI/Panel 的 VolumeWriting 只建模
// `write(level:)`，与本写入器语义完全匹配，无需 adapter；`toggleMute()` /
// `readCurrentLevel()` 是本类型超出协议的附加能力，供组合根（LiveServices/
// AutomationCoordinator）按具体类型调用，协议面保持不动。

// MARK: - AppleScript 源串生成（Display 域自持）

/// 系统音量落点串生成器。UI/Panel 已有同形 VolumeScript，但依赖单向铁律禁止
/// Display 域反向取用 UI 层，这里自写一份保持同形；两处串面各自被测试字面钉死，
/// 漂移会在测试侧暴露（串面 = AppleScript `set volume` 的公开口径，非自研协议）。
enum DisplayVolumeScript {
    static func clamp(_ level: Int) -> Int { min(max(level, 0), 100) }

    static func outputVolumeScript(for level: Int) -> String {
        "set volume output volume \(clamp(level))"
    }

    static var toggleMuteScript: String { "set volume output muted (not (output muted))" }
}

// MARK: - 决策与回退矩阵（纯函数，测试直钉）

/// DDC 域一次 setLevel 的执行判定
public enum DDCApplyOutcome: Equatable, Sendable {
    /// DDC 写入且回读校验通过
    case applied
    /// 需回退系统音量（降级计数的分类依据）
    case fallback(DDCFallbackReason)
}

/// 回退原因：失败面全覆盖（客户端缺位/枚举不到屏/写失败/回读不符），
/// 供降级计数与日志分级，不用于重试（DDC-04：静默降级，不硬重试）
public enum DDCFallbackReason: Equatable, Sendable {
    case ddcClientMissing
    case displayNotFound
    case writeRejected
    case verifyFailed(readBack: Int?, expected: Int)
}

/// 路由 → 落点的全部裁决矩阵。纯函数化是为可测：显示器 I2C 行为没法在 CI 上
/// 复现，矩阵先行钉死，IO 层只负责把结果喂进来
public enum RoutedVolumeDecision {
    /// 回读容差：readValue 已按 cur/max 折算 0-100，但不同显示器 MCCS 满量程
    /// 不一（0-100/0-255），量化舍入仍可能差 1 档；容差 2 覆盖量化噪声，
    /// 又不至于放过"写 80 读回 8"一类的真失败
    public static let readBackTolerance = 2

    /// .ddc 路由下 (写结果, 回读值) → 落点。前置两参（客户端/显示器在场）供
    /// 无 IO 环境直接钉矩阵，IO 路径恒传 true
    public static func ddcOutcome(
        ddcPresent: Bool,
        displayFound: Bool,
        writeSucceeded: Bool,
        readBack: Int?,
        expected: Int,
        tolerance: Int = readBackTolerance
    ) -> DDCApplyOutcome {
        guard ddcPresent else { return .fallback(.ddcClientMissing) }
        guard displayFound else { return .fallback(.displayNotFound) }
        guard writeSucceeded else { return .fallback(.writeRejected) }
        guard let readBack, abs(readBack - expected) <= tolerance else {
            return .fallback(.verifyFailed(readBack: readBack, expected: expected))
        }
        return .applied
    }

    /// 静音去向恒系统的裁决（纯函数钉死，路由无权改判）。
    /// 决策依据：MCCS 0x8C audio mute 各家实现不一——有的不支持、有的静音即
    /// 音量减半、有的写后不回读，误写会让"取消静音"永远修不回来；而 macOS
    /// 对 HDMI/DP 音频做软件静音同样生效，系统静音无功能损失，误判代价不对称。
    public static func muteAlwaysUsesSystem() -> Bool { true }
}

// MARK: - 组合写入器

/// 组合音量写入器：VolumeWriting 协议的 DDC/系统双路由实现。
/// 结构体拷贝共享降级计数（引用语义的计数器是唯一可变态，锁内收敛）
public struct RoutedVolumeWriter: VolumeWriting {
    /// 系统音量落点。默认走 AppleScript（与 UI/Panel 的 AppleScriptVolumeWriter
    /// 同式：detached 执行，NSAppleEventDescriptor 非 Sendable 不跨任务携带）；
    /// 测试注入记录闭包观察回退行为（串字面自测，绝不执行）
    public typealias SystemWrite = @Sendable (Int) async -> Void

    public let ddc: DDCClient?
    public let routeDecision: @Sendable () -> DDCVolumeRoute
    public let currentVolume: @Sendable () -> Int
    let systemWrite: SystemWrite
    private let degradeCounter = DegradeCounter()

    public init(
        ddc: DDCClient?,
        routeDecision: @escaping @Sendable () -> DDCVolumeRoute,
        currentVolume: @escaping @Sendable () -> Int
    ) {
        self.init(
            ddc: ddc, routeDecision: routeDecision, currentVolume: currentVolume,
            systemWrite: Self.appleScriptSystemWrite
        )
    }

    init(
        ddc: DDCClient?,
        routeDecision: @escaping @Sendable () -> DDCVolumeRoute,
        currentVolume: @escaping @Sendable () -> Int,
        systemWrite: @escaping SystemWrite
    ) {
        self.ddc = ddc
        self.routeDecision = routeDecision
        self.currentVolume = currentVolume
        self.systemWrite = systemWrite
    }

    /// 协议面：写音量档位（0...100）。.ddc 路由写后回读校验一次，失败回退
    /// 系统并记降级；.system 直走 AppleScript
    public func write(level: Int) async {
        let clamped = DisplayVolumeScript.clamp(level)
        switch routeDecision() {
        case .system:
            await systemWrite(clamped)
        case .ddc:
            await writeViaDDC(clamped)
        }
    }

    /// 附加能力（超协议面）：静音切换恒走系统（裁决见 RoutedVolumeDecision.muteAlwaysUsesSystem）
    public func toggleMute() async {
        let source = DisplayVolumeScript.toggleMuteScript
        await Task.detached(priority: .userInitiated) { () -> Void in
            _ = NSAppleScript(source: source)?.executeAndReturnError(nil)
        }.value
    }

    /// 附加能力（超协议面）：路由感知的当前档位读回。.ddc → 读显示器 0x62
    /// （读不到回退注入闭包）；.system → 注入闭包。供步进（T-210）与面板乐观显示取初值
    public func readCurrentLevel() -> Int {
        switch routeDecision() {
        case .system:
            return currentVolume()
        case .ddc:
            guard let ddc, let display = ddc.discoverDisplays().first,
                  let readBack = ddc.readVolume(of: display) else { return currentVolume() }
            return readBack
        }
    }

    /// DDC 域累计回退次数：面板/日志可据此提示"DDC 音量已降级系统"
    public var ddcFallbackCount: Int { degradeCounter.value }

    // MARK: 内部

    private func writeViaDDC(_ level: Int) async {
        switch ddcApplyOutcome(for: level) {
        case .applied:
            break
        case .fallback:
            degradeCounter.increment()
            await systemWrite(level)
        }
    }

    /// IO 半场：执行写+回读，结果交给纯函数矩阵裁决。
    /// 写失败即短路（不再发无谓的读请求——矩阵对 writeSucceeded=false 恒 writeRejected）。
    /// I2C 双包实测毫秒级且 writeDDC 保持单轮无重试（DDC-04），不另起 detached
    private func ddcApplyOutcome(for level: Int) -> DDCApplyOutcome {
        guard let ddc else {
            return RoutedVolumeDecision.ddcOutcome(
                ddcPresent: false, displayFound: false,
                writeSucceeded: false, readBack: nil, expected: level
            )
        }
        let displays = ddc.discoverDisplays()
        guard let display = displays.first else {
            return RoutedVolumeDecision.ddcOutcome(
                ddcPresent: true, displayFound: false,
                writeSucceeded: false, readBack: nil, expected: level
            )
        }
        let wrote = ddc.writeVolume(level, to: display)
        let readBack = wrote ? ddc.readVolume(of: display) : nil
        return RoutedVolumeDecision.ddcOutcome(
            ddcPresent: true, displayFound: true,
            writeSucceeded: wrote, readBack: readBack, expected: level
        )
    }

    /// 默认系统落点：与 AppleScriptVolumeWriter 同式（闭包显式返回 Void，
    /// 执行结果 NSAppleEventDescriptor 非 Sendable，不跨任务边界携带）
    static let appleScriptSystemWrite: SystemWrite = { level in
        let source = DisplayVolumeScript.outputVolumeScript(for: level)
        await Task.detached(priority: .userInitiated) { () -> Void in
            _ = NSAppleScript(source: source)?.executeAndReturnError(nil)
        }.value
    }
}

// MARK: - live 路由工厂

extension RoutedVolumeWriter {
    /// 组合根路由判定工厂：defaultOutputModelUID()（DDCVolume.swift 已有）+
    /// DDCClient 可用性。每次写入现算——用户可能随时把默认输出切到别的设备，
    /// 缓存判定会让滑杆写进已断开的显示器
    public static func liveRoute() -> @Sendable () -> DDCVolumeRoute {
        // DDCClient 无状态且可用性由 dlsym 进程级判定一次，工厂内建一个即可
        let client = DDCClient()
        return {
            DDCRouting.volumeRoute(
                defaultOutputModelUID: DDCRouting.defaultOutputModelUID(),
                ddcAvailable: client.isAvailable
            )
        }
    }
}

// MARK: - 降级计数

/// 结构体写入器的共享可变态。@unchecked 论证：可变 count 只经 NSLock 内的
/// 唯二入口（increment/value）触达，无逃逸；拷贝共享计数是刻意的（同一写入器
/// 的各拷贝应看到同一条降级历史）
final class DegradeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }

    var value: Int { lock.withLock { count } }
}

extension RoutedVolumeWriter {
    /// AutomationGlue 同步闭包桥：系统路由 AppleScript 同步；DDC 路由拒绝（异步路径，步进暂走系统）
    public func readCurrentLevelSync() -> Int { readCurrentLevel() }
    public func writeSync(level: Int) -> ActionOutcome {
        let clamped = min(max(level, 0), 100)
        let script = NSAppleScript(source: "set volume output volume \(clamped)")
        return script?.executeAndReturnError(nil) == nil ? .performed : .rejected(reason: "AppleScript 失败")
    }
}
