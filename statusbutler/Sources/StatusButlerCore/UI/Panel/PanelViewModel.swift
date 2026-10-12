import Combine
import Foundation

// MARK: - 温度域旁路读取协议（T-030）

/// 面板温度旁路的可注入抽象（沿用 `-ing` 后缀惯例）。
/// ThermalMonitor 是 struct 且无协议（T-025 只做读路径），本文件不改它、
/// 仅作同模块 retroactive 包装，让面板/测试能注入假实现
public protocol ThermalMonitoring: Sendable {
    func read() async -> ThermalSnapshot?
}

extension ThermalMonitor: ThermalMonitoring {}

// MARK: - 可见性守门人（S3 能效纪律）

/// 弹层可见性状态的唯一载体（S3"有人看才运行"的闸门）。
/// 可见性有两个来源——NSPopover 委托回调（壳层）与 SwiftUI onAppear/onDisappear（内容层），
/// 双方都汇入 setVisible；下游订阅 removeDuplicates 去重，重复上报不会重启采样链。
/// 由本类而非 NSPopover 持有状态，是为了让 PanelViewModel 不依赖 AppKit 也可单测启停
@MainActor
public final class PopoverVisibilityTracker: ObservableObject {
    @Published public private(set) var isVisible: Bool = false

    public init() {}

    public func setVisible(_ visible: Bool) {
        isVisible = visible
    }
}

// MARK: - 面板视图模型（T-030）

/// 弹层面板 VM。数据分两类，采样纪律不同（A2·S3）：
/// - 快照数据（电池/网络/音量）：SystemStatusStore 常驻轮询本来就为菜单栏图标而跑，
///   VM 只订阅其 $snapshot，经 500ms 防抖合并后落到 displaySnapshot 驱动面板重绘；
/// - 旁路数据（蓝牙/温度）：只服务面板、绝不做进图标渲染键（架构铁律 3），
///   只在弹层可见期间采样——出现瞬间各读一次 + 粗间隔轮询，消失即 cancel。
@MainActor
public final class PanelViewModel: ObservableObject {
    /// S3 规格：打开时数据 500ms 防抖合并（窗口内多次变更只下发末值一次）
    public static let snapshotDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(500)
    /// 旁路轮询默认粗间隔：蓝牙/温度都是毫秒级轻读，5s 对面板观感足够；
    /// 睡眠 tolerance = 间隔/5（B1：不要求 CPU 精确唤醒）
    public static let defaultBypassPollInterval: Duration = .seconds(5)

    @Published public private(set) var layout: PanelLayout
    /// 防抖后的快照（面板唯一的数据出口——不直接绑 store.$snapshot，防抖才有意义）
    @Published public private(set) var displaySnapshot: StatusSnapshot
    @Published public private(set) var bluetoothDevices: [BluetoothDeviceInfo] = []
    @Published public private(set) var thermal: ThermalSnapshot?
    @Published public private(set) var popoverVisible: Bool = false

    /// 旁路采样启停标志（测试与接线方可观测；不可见恒为 false）
    public var isBypassSamplingActive: Bool {
        bluetoothPollTask != nil || thermalPollTask != nil
    }

    /// 实际要渲染的分区：order ∩ visibleSections，保持 order 的排列
    public var sectionsToRender: [PanelSectionID] {
        layout.order.filter { layout.visibleSections.contains($0) }
    }

    private let store: SystemStatusStore
    private let bluetooth: any BluetoothMonitoring
    private let thermalMonitor: any ThermalMonitoring
    private let visibilityTracker: PopoverVisibilityTracker
    private let bypassPollInterval: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var bluetoothPollTask: Task<Void, Never>?
    private var thermalPollTask: Task<Void, Never>?

    public init(
        store: SystemStatusStore,
        bluetooth: any BluetoothMonitoring = BluetoothMonitor(),
        thermal: any ThermalMonitoring = ThermalMonitor(),
        visibilityTracker: PopoverVisibilityTracker = PopoverVisibilityTracker(),
        layout: PanelLayout = .default,
        bypassPollInterval: Duration = PanelViewModel.defaultBypassPollInterval
    ) {
        self.store = store
        self.bluetooth = bluetooth
        self.thermalMonitor = thermal
        self.visibilityTracker = visibilityTracker
        // 非法布局（旧数据缺新分区 id 等）不整体丢弃，净化后收用
        self.layout = layout.isValid ? layout : layout.sanitized()
        self.bypassPollInterval = bypassPollInterval
        self.displaySnapshot = store.snapshot
        self.popoverVisible = visibilityTracker.isVisible
        bind()
    }

    deinit {
        // 弱引用循环本会自行退出，这里同步 cancel 让"close 即停"在 VM 生命周期尽头也成立
        bluetoothPollTask?.cancel()
        thermalPollTask?.cancel()
    }

    // MARK: - 生命周期钩子（SwiftUI onAppear/onDisappear 接这里）

    /// 弹层内容出现：开启旁路采样（读一次 + 粗间隔轮询）
    public func panelDidAppear() {
        visibilityTracker.setVisible(true)
    }

    /// 弹层内容消失：cancel 全部旁路采样
    public func panelWillDisappear() {
        visibilityTracker.setVisible(false)
    }

    /// 更新分区布局（设置页显隐勾选/拖动排序接入用）；非法布局原样拒绝，不半途应用
    public func apply(layout newLayout: PanelLayout) {
        guard newLayout.isValid else { return }
        layout = newLayout
    }

    // MARK: - 绑定

    private func bind() {
        // 快照防抖管道（S3"打开时数据 500ms 防抖合并"）：
        // store 每轮轮询都 willSet 一次 snapshot，直接订阅会让面板跟着每轮重绘；
        // removeDuplicates 先滤掉相等快照（能效铁律：订阅去重），
        // debounce 再把 500ms 静默窗口内的多次变更合并成末值一次下发——
        // 打开瞬间各域集中刷新时面板只重绘一次
        store.$snapshot
            .removeDuplicates()
            .debounce(for: Self.snapshotDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.displaySnapshot = snapshot
            }
            .store(in: &cancellables)

        // 可见性 → 旁路启停（S3 能效纪律唯一闸门；removeDuplicates 吸收双通道重复上报）
        visibilityTracker.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.popoverVisible = visible
                if visible {
                    self?.startBypassSampling()
                } else {
                    self?.stopBypassSampling()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 旁路采样（可见期间才存在）

    private func startBypassSampling() {
        // 防重入：先撤旧链再起新链，重复的"出现"上报不会叠加轮询
        stopBypassSampling()
        bluetoothPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.bluetoothDevices = await self.bluetooth.read()
                }
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(
                    for: self.bypassPollInterval,
                    tolerance: self.bypassPollInterval / 5
                )
            }
        }
        thermalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.thermal = await self.thermalMonitor.read()
                }
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(
                    for: self.bypassPollInterval,
                    tolerance: self.bypassPollInterval / 5
                )
            }
        }
    }

    private func stopBypassSampling() {
        bluetoothPollTask?.cancel()
        bluetoothPollTask = nil
        thermalPollTask?.cancel()
        thermalPollTask = nil
    }
}
