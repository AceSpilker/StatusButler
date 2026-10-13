import AppKit
import SwiftUI

// MARK: - 分区行卡片（A2·S3：图标 + 主值 + 副标题；A14-β 增加可选下钻按钮）

/// 统一的分区行卡片骨架；各行视图只负责把各自数据映射成三段文案（纯函数化，便于将来补测）。
/// trailing 供分区行挂下钻 chevron（A14-β 导航入口）
private struct SectionRowCard<Trailing: View>: View {
    let symbolName: String
    let title: String
    let value: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

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
            trailing()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

extension SectionRowCard where Trailing == EmptyView {
    init(symbolName: String, title: String, value: String, subtitle: String) {
        self.init(symbolName: symbolName, title: title, value: value, subtitle: subtitle) {
            EmptyView()
        }
    }
}

/// 下钻 chevron 按钮（分区行 → 下钻页的统一入口样式）
struct DrillDownButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label).font(.caption)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 各分区行

/// 电池行：百分比主值 + 下钻电池详情；快照的 BatteryState.unavailable 在台式机上真实存在
private struct BatteryRow: View {
    let battery: BatteryState
    let onDrillDown: () -> Void

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.battery.symbolName,
            title: PanelSectionID.battery.displayName,
            value: Self.valueText(for: battery),
            subtitle: Self.subtitleText(for: battery)
        ) {
            DrillDownButton(label: "详情", action: onDrillDown)
        }
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

/// 网络行：快照 link 为主信息；ConnectionDetails 注入后 VPN/受限徽标点亮
/// （OG-FR-141"VPN 状态行只显示，不进图标渲染键"——徽标只活在面板旁路）。
/// 非 private：hasBadge 决策表被 PanelCompleteTests 直接钉死
struct NetworkRow: View {
    let link: NetworkLink
    var connectionDetails: ConnectionDetails?
    let onDrillDown: () -> Void

    var body: some View {
        SectionRowCard(
            symbolName: PanelSectionID.network.symbolName,
            title: PanelSectionID.network.displayName,
            value: Self.valueText(for: link),
            subtitle: Self.subtitleText(for: link)
        ) {
            DrillDownButton(label: "详情", action: onDrillDown)
        }
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

/// 音量行：可写滑杆 + 行内滚轮调节（A2·S3"A14-β 音量可调"）。
/// 滚轮捕捉层只盖标题卡片区（slider 保留直接拖动——NSView 覆盖会吞掉拖拽手势）
private struct VolumeRow: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 6) {
            SectionRowCard(
                symbolName: PanelSectionID.volume.symbolName,
                title: PanelSectionID.volume.displayName,
                value: "\(viewModel.volumeDisplay.level)%",
                subtitle: Self.subtitleText(for: viewModel.volumeDisplay, writable: viewModel.isVolumeWritable)
            )
            .overlay(
                ScrollWheelCatcher { deltaY in
                    viewModel.scrollVolume(deltaY: deltaY)
                }
            )
            Slider(
                value: Binding(
                    get: { Double(viewModel.volumeDisplay.level) },
                    set: { viewModel.setVolume(Int($0.rounded())) }
                ),
                in: 0...100
            )
            .disabled(!viewModel.isVolumeWritable)
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    static func subtitleText(for volume: VolumeState, writable: Bool) -> String {
        if volume.isMuted { return "已静音" }
        return writable ? "音量 · 行内滚轮可调" : "音量（只读）"
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

// MARK: - 蓝牙分区（A2·S7：摘要 + 设备行操作 + 电量列 + AirPods 展开）

private struct BluetoothRow: View {
    @ObservedObject var viewModel: PanelViewModel
    let devices: [BluetoothDeviceInfo]
    let rows: [BluetoothDeviceWithBattery]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionRowCard(
                symbolName: PanelSectionID.bluetooth.symbolName,
                title: PanelSectionID.bluetooth.displayName,
                value: BluetoothSummary.valueText(for: devices),
                subtitle: BluetoothSummary.subtitleText(for: devices)
            )
            ForEach(rows, id: \.info.address) { row in
                BluetoothDeviceRow(
                    row: row,
                    isArmed: viewModel.hidArmedAddress == row.info.address,
                    onToggle: { viewModel.toggleBluetoothDevice(row.info) }
                )
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

/// 蓝牙摘要文案（纯函数抽离，与 BatteryRow 同惯例）
enum BluetoothSummary {
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

/// 单设备行：名称 + 电量列 + 连接/断开；HID 断开走"再点一次"确认；AirPods 三仓位展开
private struct BluetoothDeviceRow: View {
    let row: BluetoothDeviceWithBattery
    let isArmed: Bool
    let onToggle: () -> Void

    @State private var showsAirPodsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: BluetoothPanelDisplay.symbolName(for: row.info.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.info.name.isEmpty ? "未命名设备" : row.info.name)
                        .font(.callout)
                    Text(row.info.isConnected ? "已连接" : "未连接")
                        .font(.caption2)
                        .foregroundStyle(row.info.isConnected ? Color.primary.opacity(0.6) : .secondary)
                }
                Spacer(minLength: 4)
                if let percent = row.batteryPercent {
                    Text("\(percent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                }
                if row.airPods != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showsAirPodsDetail.toggle()
                        }
                    } label: {
                        Image(systemName: showsAirPodsDetail ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("三仓位电量")
                }
                Button(action: onToggle) {
                    Text(toggleLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                isArmed ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.2)
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            if showsAirPodsDetail, let airPods = row.airPods {
                Text(BluetoothPanelDisplay.airPodsSummary(airPods))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 2)
    }

    /// HID 断开的待确认态换文案（A2·S7"再点一次"）；其余动作直达
    private var toggleLabel: String {
        if row.info.isConnected {
            return isArmed ? "再点一次断开" : "断开"
        }
        return "连接"
    }
}

// MARK: - 顶部动作行（A3·E2 动作中心面板行）

struct ActionStripView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.actions, id: \.id) { action in
                    ActionStripItemView(
                        action: action,
                        // 灰显两级：本机不支持 / 执行器未接线（AC-02：无执行面绝不伪装可点）
                        isDisabled: ActionStripStyling.isDisabled(for: action.availability)
                            || !viewModel.isActionCenterArmed
                    ) {
                        _ = viewModel.perform(action)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 46)
    }
}

/// 单动作按钮：图标 + 标题 + availability 徽标（AC-02 诚实分级）
struct ActionStripItemView: View {
    let action: ButlerAction
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: action.symbolName)
                        .font(.callout)
                    if let badge = ActionStripStyling.badgeText(for: action.availability) {
                        Text(badge)
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                    }
                }
                Text(action.title).font(.caption2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isDisabled
                            ? AnyShapeStyle(.quaternary.opacity(0.3))
                            : AnyShapeStyle(.secondary.opacity(0.14))
                    )
            )
            .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - 天气/日程行（A8·WX/CAL：provider 无数据时整行隐藏）

struct InfoStripView: View {
    let weatherText: String?
    let calendarText: String?

    var body: some View {
        HStack(spacing: 8) {
            if let weatherText {
                InfoStripChip(symbolName: "cloud.sun.fill", text: weatherText)
            }
            if let calendarText {
                InfoStripChip(symbolName: "calendar", text: calendarText)
            }
        }
    }
}

private struct InfoStripChip: View {
    let symbolName: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }
}

// MARK: - 体检入口行（A3·E18）

struct HealthEntryRowView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        Button {
            viewModel.push(.healthReport)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("健康体检").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                scoreText
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        viewModel.healthReport == nil ? "点开跑一轮系统体检" : "FileVault/Gatekeeper/防火墙/更新"
    }

    @ViewBuilder private var scoreText: some View {
        if let report = viewModel.healthReport {
            Text("\(report.score) 分")
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(HealthScoreColor.color(for: HealthScoreTier.tier(forScore: report.score)))
        } else {
            Text("—").font(.title3)
        }
    }
}

/// 体检分数色档 → 颜色（电池健康度同用：语义同为 好/中/差 三档）
enum HealthScoreColor {
    static func color(for tier: HealthScoreTier) -> Color {
        switch tier {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

// MARK: - footer 槽位行（A14-β：当前槽位 + 点击循环）

struct SlotFooterView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 6) {
            Divider()
            Button {
                viewModel.cycleSlot()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.slotLabel ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary.opacity(0.4)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换信号槽位（当前 \(viewModel.slotLabel ?? "")）")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 面板根视图

/// 弹层面板根视图：概览根页按 layout 的 order 序渲染可见分区（A2·S3 分区化内容）；
/// 下钻页经 PanelRoute 导航栈切换（A14-β）。onAppear/onDisappear 接 VM 的可见性钩子——
/// 出现即开旁路采样、消失即停（能效纪律）
public struct StatusPanelRootView: View {
    @ObservedObject private var viewModel: PanelViewModel

    public init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if let route = viewModel.currentRoute {
                PanelPageContainer(route: route, viewModel: viewModel)
            } else {
                overview
            }
        }
        .padding(12)
        // 定宽：让 NSHostingController 的 preferredContentSize 只随高度伸缩，
        // 弹层重开尺寸稳定；概览根页不用 ScrollView——分区少，整版可容纳，
        // 避免滚动视图吃掉固有高度（下钻页内容长，各自内嵌 ScrollView）
        .frame(width: 340)
        .onAppear { viewModel.panelDidAppear() }
        .onDisappear { viewModel.panelWillDisappear() }
    }

    private var overview: some View {
        VStack(spacing: 8) {
            if !viewModel.actions.isEmpty {
                ActionStripView(viewModel: viewModel)
            }
            ForEach(viewModel.sectionsToRender, id: \.self) { section in
                row(for: section)
            }
            if viewModel.showsInfoStrip {
                InfoStripView(weatherText: viewModel.weatherText, calendarText: viewModel.calendarText)
            }
            if viewModel.showsHealthRow {
                HealthEntryRowView(viewModel: viewModel)
            }
            if viewModel.slotLabel != nil {
                SlotFooterView(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private func row(for section: PanelSectionID) -> some View {
        switch section {
        case .battery:
            BatteryRow(
                battery: viewModel.displaySnapshot.battery,
                onDrillDown: { viewModel.push(.batteryDetails) }
            )
        case .network:
            NetworkRow(
                link: viewModel.displaySnapshot.link,
                connectionDetails: viewModel.connectionDetails,
                onDrillDown: { viewModel.push(.linkDetails) }
            )
        case .volume:
            VolumeRow(viewModel: viewModel)
        case .bluetooth:
            BluetoothRow(
                viewModel: viewModel,
                devices: viewModel.bluetoothDevices,
                rows: viewModel.bluetoothBatteryRows
            )
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
