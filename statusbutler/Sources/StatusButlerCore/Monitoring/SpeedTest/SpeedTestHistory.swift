import Combine
import Foundation

// T-217（E10 集成注记）：测速历史——本任务只做内存缓存（弹层显示最近 5 次）。
// 持久化留集成：HistoryDatabase 加 speedtest_results 表（或独立 JSON 快照）均可，
// 接线时把 record() 挂上落库即可，内存结构即落库行的形状。

/// 测速历史缓存：@MainActor ObservableObject（Store/控制器主线程纪律，PerfFeed 同源），
/// 弹层直接 @ObservedObject 订阅 recent。
@MainActor
public final class SpeedTestHistory: ObservableObject {
    /// 弹层展示容量：最近 5 次
    public static let capacity = 5

    @Published public private(set) var recent: [SpeedTestResult]

    public init(recent: [SpeedTestResult] = []) {
        // 预置超容时留最新的尾部（与 record 同一裁剪方向）
        self.recent = Array(recent.suffix(Self.capacity))
    }

    /// 记一次结果：超出容量即裁最旧的（FIFO 环）
    public func record(_ result: SpeedTestResult) {
        recent.append(result)
        if recent.count > Self.capacity {
            recent.removeFirst(recent.count - Self.capacity)
        }
    }

    public var mostRecent: SpeedTestResult? { recent.last }
}
