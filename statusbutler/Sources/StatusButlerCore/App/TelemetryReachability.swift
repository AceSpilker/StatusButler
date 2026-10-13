import Foundation
import Network

// 遥测资格的网络轴（A2·S11·OG-FR-201 三轴之一）：NWPathMonitor 常驻采样成布尔快照，
// 供 TelemetryScheduler 的 @Sendable networkReachable 闭包同步读取。
// 只服务"要不要发心跳"的廉价判定（tick 每小时一次），不做任何 UI 通知。

/// @unchecked Sendable 论证：唯一可变态 satisfied 的读写全经 NSLock；
/// monitor 回调线程不定，lock 外无共享可变态
final class TelemetryReachability: @unchecked Sendable {
    /// 默认可达：网络轴是"省一次注定失败的心跳"的优化而非安全闸——宁可多试不可漏发
    private let lock = NSLock()
    private var satisfied = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "statusbutler.telemetry.reachability")

    var isReachable: Bool {
        lock.withLock { satisfied }
    }

    /// 生命周期注释：本对象由组合根创建、经 networkReachable 闭包被调度器持有——
    /// 调度器存活即采样存活，环境释放时随闭包链一起释放，无单例悬挂
    func start() {
        // pathUpdateHandler 而非 paths 异步序列：本工具链 SDK 无后者成员；
        // handler 线程不定正是可变态全走 NSLock 的原因
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func update(_ value: Bool) {
        lock.withLock { satisfied = value }
    }
}
