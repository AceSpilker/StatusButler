import AppKit
import SwiftUI

// MARK: - 分区行卡片（A2·S3：图标 + 主值 + 副标题）

/// 统一的分区行卡片骨架；各行视图只负责把各自数据映射成三段文案（纯函数化，便于将来补测）
private struct SectionRowCard: View {
    let symbolName: String
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.title3)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

// MARK: - 各分区行

/// 电池行：百分比主值；快照的 BatteryState.unavailable 在台式机上真实存在，如实显示占位
private struct BatteryRow: View {
    let battery: BatteryState

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.battery.symbolName,
            title: PanelSectionID.battery.displayName,
            value: Self.valueText(for: battery),
            subtitle: Self.subtitleText(for: battery)
        )
    }

    static func valueText(for battery: BatteryState) -> String {
        switch battery {
        case .battery(let level, _): return "\(level)%"
        case .unavailable: return "—"
        }
    }

    static func subtitleText(for battery: BatteryState) -> String {
        switch battery {
        case .battery(_, true): return "充电中"
        case .battery(_, false): return "使用电池"
        case .unavailable: return "无电池（台式机）"
        }
    }
}

/// 网络行：快照 link 为主信息；VPN/受限徽标为占位——ConnectionDetails（T-024 监控器）
/// 尚未接入面板旁路，接线后传入即点亮（OG-FR-141"VPN 状态行只显示，不进图标渲染键"）
private struct NetworkRow: View {
    let link: NetworkLink
    var connectionDetails: ConnectionDetails?

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.network.symbolName,
            title: PanelSectionID.network.displayName,
            value: Self.valueText(for: link),
            subtitle: Self.subtitleText(for: link)
        )
        .overlay(alignment: .trailing) {
            // 徽标叠在卡片右缘、主值左侧，避免文案换行挤压
            if Self.hasBadge(link: link, details: connectionDetails) {
                badges
                    .padding(.trailing, 56)
            }
        }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if connectionDetails?.isVPN == true {
                badge("VPN")
            }
            if connectionDetails?.isConstrained == true {
                badge("低数据")
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.secondary.opacity(0.25)))
    }

    static func hasBadge(link: NetworkLink, details: ConnectionDetails?) -> Bool {
        // 离线时链路本来不可用，受限/VPN 徽标无意义
        if case .offline = link { return false }
        guard let details else { return false }
        return details.isVPN || details.isConstrained
    }

    static func valueText(for link: NetworkLink) -> String {
        switch link {
        case .wifi(let ssid, _): return ssid ?? "Wi-Fi"
        case .wired: return "有线"
        case .offline: return "离线"
        }
    }

    static func subtitleText(for link: NetworkLink) -> String {
        switch link {
        case .wifi(_, let bars): return "Wi-Fi · 信号 \(bars)/4"
        case .wired: return "以太网已连接"
        case .offline: return "未连接网络"
        }
    }
}

/// 音量行：只读展示。写路径（滑杆/滚轮改音量、作用域与方向配置）不在本任务
// TODO(T-030b 音量写路径): Slider 换成可写 Binding + store 增加音量写通道；S3"滚动调音量"同批接入
private struct VolumeRow: View {
    let volume: VolumeState

    var body: some View {
        VStack(spacing: 6) {
            SectionRowCard(
                symbolName: PanelSectionID.volume.symbolName,
                title: PanelSectionID.volume.displayName,
                value: "\(volume.level)%",
                subtitle: volume.isMuted ? "已静音" : "音量"
            )
            // 只读滑杆：constant 绑定 + disabled，纯视觉展示当前档位
            Slider(value: .constant(Double(volume.level) / 100))
                .disabled(true)
                .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

/// 蓝牙行：配对/连接计数摘要；设备列表就地展开属 S3 下钻（后续任务），本版只做摘要行
private struct BluetoothRow: View {
    let devices: [BluetoothDeviceInfo]

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.bluetooth.symbolName,
            title: PanelSectionID.bluetooth.displayName,
            value: Self.valueText(for: devices),
            subtitle: Self.subtitleText(for: devices)
        )
    }

    static func valueText(for devices: [BluetoothDeviceInfo]) -> String {
        let connected = devices.filter(\.isConnected).count
        return connected > 0 ? "\(connected) 已连接" : "未连接"
    }

    static func subtitleText(for devices: [BluetoothDeviceInfo]) -> String {
        guard !devices.isEmpty else { return "未发现配对设备" }
        let connected = devices.filter(\.isConnected).count
        return "\(connected)/\(devices.count) 已连接 · 共 \(devices.count) 台配对"
    }
}

/// 温度行：最高温主值 + 风扇 RPM 副标题；thermal == nil 是真实状态
/// （无 SMC 的虚拟机），如实显示不可用，绝不显示假数据
private struct ThermalRow: View {
    let thermal: ThermalSnapshot?

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.thermal.symbolName,
            title: PanelSectionID.thermal.displayName,
            value: Self.valueText(for: thermal),
            subtitle: Self.subtitleText(for: thermal)
        )
    }

    static func valueText(for thermal: ThermalSnapshot?) -> String {
        guard let max = thermal?.maxCelsius else { return "—" }
        return String(format: "%.1f°C", max)
    }

    static func subtitleText(for thermal: ThermalSnapshot?) -> String {
        guard let thermal else { return "温度不可用" }
        if let rpm = thermal.fans.map(\.currentRPM).max() {
            return "风扇最高 \(rpm) RPM · \(thermal.sensors.count) 个传感器"
        }
        return "无风扇 · \(thermal.sensors.count) 个传感器"
    }
}

/// 性能行：占位。CpuMonitor/MemoryMonitor 读路径已在 T-027 就绪，
// TODO(T-031+ 性能旁路): 面板 VM 增加可见期 CPU/内存旁路采样后回填本行
private struct PerformanceRow: View {
    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.performance.symbolName,
            title: PanelSectionID.performance.displayName,
            value: "—",
            subtitle: "性能采样待接入"
        )
    }
}

// MARK: - 面板根视图

/// 弹层面板根视图：按 layout 的 order 序渲染可见分区（A2·S3 分区化内容）。
/// onAppear/onDisappear 接 VM 的可见性钩子——出现即开旁路采样、消失即停（能效纪律）
public struct StatusPanelRootView: View {
    @ObservedObject private var viewModel: PanelViewModel

    public init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.sectionsToRender, id: \.self) { section in
                row(for: section)
            }
        }
        .padding(12)
        // 定宽：让 NSHostingController 的 preferredContentSize 只随高度伸缩，
        // 弹层重开尺寸稳定；不用 ScrollView——分区少，整版可容纳，避免滚动视图吃掉固有高度
        .frame(width: 320)
        .onAppear { viewModel.panelDidAppear() }
        .onDisappear { viewModel.panelWillDisappear() }
    }

    @ViewBuilder
    private func row(for section: PanelSectionID) -> some View {
        switch section {
        case .battery:
            BatteryRow(battery: viewModel.displaySnapshot.battery)
        case .network:
            NetworkRow(link: viewModel.displaySnapshot.link)
        case .volume:
            VolumeRow(volume: viewModel.displaySnapshot.volume)
        case .bluetooth:
            BluetoothRow(devices: viewModel.bluetoothDevices)
        case .thermal:
            ThermalRow(thermal: viewModel.thermal)
        case .performance:
            PerformanceRow()
        }
    }
}

// MARK: - AppKit 壳桥（供 NSPopover.contentViewController 使用）

/// 包 SwiftUI 面板的 NSViewController，作为 NSPopover 的内容控制器。
/// 尺寸策略：hosting 的 sizingOptions = .preferredContentSize，弹层由 SwiftUI
/// 固有尺寸驱动，不需要外部给定 contentSize
@MainActor
public final class PopoverContentViewController: NSViewController {
    private let hostingController: NSHostingController<StatusPanelRootView>

    public init(viewModel: PanelViewModel) {
        hostingController = NSHostingController(rootView: StatusPanelRootView(viewModel: viewModel))
        super.init(nibName: nil, bundle: nil)
        hostingController.sizingOptions = .preferredContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let container = NSView()
        view = container
        addChild(hostingController)
        let hosted = hostingController.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// 把 SwiftUI 固有尺寸转发给弹层（NSPopover 优先读 contentViewController 的
    /// preferredContentSize；不自设内容尺寸的写入路径）
    override public var preferredContentSize: NSSize {
        get { hostingController.preferredContentSize }
        set { super.preferredContentSize = newValue }
    }
}
