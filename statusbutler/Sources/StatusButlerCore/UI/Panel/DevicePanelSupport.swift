import Foundation

// T-204 / T-205（C2 弹层区）：音频输入行与 iDevice 占位行的 provider 类型与展示映射。
// 两行同为"面板旁路"数据（架构铁律 3：画不进图标的不进 StatusSnapshot），
// provider 未接线即整行隐藏——诚实降级，不显示假零值。

// MARK: - 旁路 provider 类型（主线接线清单见 PanelViewModel.init 各参数注记）

/// 性能：即时读最近一帧（组合根喂 `{ perfFeed.sample }` 或 `{ perfEngine.bus.sample }`）。
/// 主线集成注记（引擎启停，"有人看才采样"）：AppEnvironment/LiveServices 在弹层
/// 可见期调 `perfEngine.start("panel")`、消失即 `stop("panel")`——引用计数与其他
/// 消费者（槽位/小组件）自动合并；本 provider 只是读端，不负责启停
public typealias PerfSampleProvider = @Sendable () -> PerfSample?
/// CPU 拓扑：开机后不变，`{ CpuCoreTopology.readLive() }` 一次读即可
public typealias CpuTopologyProvider = @Sendable () -> CpuCoreTopology?
/// 音频输入：喂 AudioInputMonitor 读数缓存。主线集成注记（T-204 设置开关默认关）：
/// 开关关时不注入 provider（行隐藏即是开关的诚实反馈）；开时在弹层可见期轮询
/// AudioInputMonitor 并缓存最近一帧，provider 读缓存
public typealias AudioInputStatusProvider = @Sendable () -> AudioInputStatus?
/// iDevice：喂 MobileBatteryHelperReader 读数折叠（MobileBatterySummary(reading:)）。
/// helper 往返是阻塞子进程，主线应在弹层可见期旁路轮询 reader 并缓存，
/// provider 只读缓存（同步闭包不做子进程往返）
public typealias MobileBatterySummaryProvider = @Sendable () -> MobileBatterySummary?

// MARK: - 音频输入行映射（T-204）

public enum AudioInputPanelMapping {
    /// 输入行三段映射；nil = 整行隐藏（provider 未接线或本轮无读数）。
    /// 设备名空（数字设备常见）降级"麦克风"——行标题不能空
    public static func texts(_ status: AudioInputStatus?) -> (deviceName: String, levelText: String, isMuted: Bool)? {
        guard let status else { return nil }
        let name = status.deviceName.isEmpty ? "麦克风" : status.deviceName
        return (name, "\(status.level)%", status.isMuted)
    }
}

// MARK: - iDevice 占位行映射（T-205）

public enum MobileBatteryPanelDisplay {
    /// 空态引导文案：无设备与 helper 不可用共用同一条（对用户两者等价于"现在没有
    /// 可展示的设备"；helper 是实现细节，不在面板里教构建命令）
    public static let emptyGuidanceText = "未检测到 Apple 设备（USB）"

    /// 设备种类 → SF Symbol（macOS 13 符号集内）
    public static func symbolName(for kind: MobileBatteryDeviceKind) -> String {
        switch kind {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .watch: return "applewatch"
        }
    }

    /// 电量列：nil（Watch 经 companion_proxy 常读不到）显示"—"，绝不编哨兵值
    public static func batteryText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "—"
    }

    /// 状态副文案：只区分"充电中/已连接"，充电态未知按已连接（不猜）
    public static func statusText(charging: Bool?) -> String {
        charging == true ? "充电中" : "已连接"
    }

    /// 分区摘要主值：N 台 / "—"
    public static func valueText(for summary: MobileBatterySummary?) -> String {
        guard let summary, !summary.devices.isEmpty else { return "—" }
        return "\(summary.total) 台"
    }

    /// 分区摘要副标题：有设备给口径提示，无设备给引导文案（与空态行同源）
    public static func subtitleText(for summary: MobileBatterySummary?) -> String {
        guard let summary, !summary.devices.isEmpty else { return emptyGuidanceText }
        return "USB 直连 · 电量实时读"
    }
}
