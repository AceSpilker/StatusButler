import AppKit
import SwiftUI

// MARK: - 下钻页容器（A14-β：Panel 内导航栈）

/// 统一的页头：返回按钮 + 页标题。push/pop 由 VM 的 routes 驱动
struct PanelPageContainer: View {
    let route: PanelRoute
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    viewModel.pop()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                        Text("返回").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回概览")
                Spacer()
                Label(route.title, systemImage: route.symbolName)
                    .font(.headline)
                Spacer()
                // 与返回按钮等宽占位，标题真正居中
                Text("返回").font(.callout).hidden()
            }
            Divider()
            page(for: route)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func page(for route: PanelRoute) -> some View {
        switch route {
        case .nearbyNetworks: NearbyNetworksPage(viewModel: viewModel)
        case .linkDetails: LinkDetailsPage(viewModel: viewModel)
        case .batteryDetails: BatteryDetailsPage(viewModel: viewModel)
        case .healthReport: HealthReportPage(viewModel: viewModel)
        }
    }
}

/// 页内通用行（键值对）
struct DetailLine: View {
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

// MARK: - 附近网络页（A2·S5 下钻一）

struct NearbyNetworksPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    viewModel.scanNearbyNetworks()
                } label: {
                    HStack(spacing: 5) {
                        if viewModel.isScanningNearby {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(viewModel.isScanningNearby ? "扫描中…" : "重新扫描")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isScanningNearby)
                Spacer()
                Text("点击网络 → 系统设置连接")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if !viewModel.nearbyNetworks.isEmpty {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(viewModel.nearbyNetworks) { network in
                        NearbyNetworkRow(network: network) {
                            viewModel.openWiFiSettings()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        } else if viewModel.isScanningNearby {
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在扫描附近的 Wi-Fi…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(scannerMissing ? "扫描服务未接入" : "未发现网络")
                .font(.callout)
            Text("SSID 显示需要定位授权（系统设置 → 隐私与安全性 → 定位服务）；未授权时仅显示信号与 BSSID")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
    }

    private var scannerMissing: Bool {
        // 扫描器未注入时不给"重新扫描"按钮错误的期望——诚实降级说明
        !viewModel.isScannerAvailable
    }
}

struct NearbyNetworkRow: View {
    let network: NearbyNetwork
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: network.signalBars >= 1 ? "wifi" : "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(network.displayName).font(.callout).lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("信号 \(network.signalBars)/4")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if network.isSecure {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if network.ssid == nil, let bssid = network.bssid, !bssid.isEmpty {
            return "SSID 需定位授权 · \(bssid)"
        }
        return network.ssid == nil ? "SSID 需定位授权" : (network.isSecure ? "加密网络" : "开放网络")
    }
}

// MARK: - 链路详情页（A2·S5 下钻二）

struct LinkDetailsPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                GroupBox("链路") {
                    VStack(alignment: .leading, spacing: 0) {
                        DetailLine(
                            title: "接口",
                            value: LinkDetailsFormatting.interfaceSummary(
                                details: viewModel.connectionDetails ?? .offline
                            )
                        )
                        ForEach(
                            LinkDetailsFormatting.flags(details: viewModel.connectionDetails ?? .offline),
                            id: \.label
                        ) { flag in
                            DetailLine(
                                title: flag.label,
                                value: flag.isOn ? "是" : "否",
                                valueColor: flag.isOn ? Color.orange : Color.secondary.opacity(0.7)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                GroupBox("地址") {
                    VStack(alignment: .leading, spacing: 0) {
                        let lines = LinkDetailsFormatting.addressLines(viewModel.linkAddresses)
                        if lines.isEmpty {
                            Text("未读取到地址（读取服务未接入或无活动接口）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(lines, id: \.self) { line in
                                DetailLine(title: String(line.split(separator: " · ").first ?? ""), value: addressPart(of: line))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("VPN 判定为 utun 隧道接口启发式（iCloud 私人中继等系统隧道可能误报），仅作提示不做安全结论")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addressPart(of line: String) -> String {
        // 行格式 "en0 · 192.168.1.5"，取地址段
        line.split(separator: " · ").dropFirst().joined(separator: " · ")
    }
}

// MARK: - 电池详情页（A2·S4 下钻三）

struct BatteryDetailsPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let details = viewModel.batteryDetail {
                    GroupBox("电池") {
                        VStack(alignment: .leading, spacing: 0) {
                            DetailLine(
                                title: "健康度",
                                value: healthText(details),
                                valueColor: HealthScoreColor.color(for: healthTierColorProxy(details))
                            )
                            DetailLine(title: "循环次数", value: optional(details.cycleCount))
                            DetailLine(
                                title: "满充容量",
                                value: optional(details.maxCapacity, suffix: " mAh")
                            )
                            DetailLine(
                                title: "设计容量",
                                value: optional(details.designCapacity, suffix: " mAh")
                            )
                        }
                        .padding(.vertical, 2)
                    }
                    GroupBox("电气") {
                        VStack(alignment: .leading, spacing: 0) {
                            DetailLine(
                                title: "电压",
                                value: BatteryDetailsMapping.voltageText(details.voltageMillivolts)
                            )
                            DetailLine(
                                title: "瞬时功率",
                                value: BatteryDetailsMapping.powerText(
                                    voltageMillivolts: details.voltageMillivolts,
                                    amperageMilliamps: details.amperageMilliamps
                                )
                            )
                            DetailLine(
                                title: "电源",
                                value: details.externalConnected ? "外接电源" : "使用电池"
                            )
                            DetailLine(
                                title: "充电中",
                                value: details.isCharging ? "是" : "否",
                                valueColor: details.isCharging ? Color.green : Color.secondary.opacity(0.7)
                            )
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "battery.0")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("未读到电池信息")
                            .font(.callout)
                        Text("台式机无 AppleSmartBattery 服务；笔记本上若持续空白，为详情读取服务未接入")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }

                GroupBox("优化充电") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("优化充电会学习你的充电习惯，暂缓充满时间以延缓电池老化。开关在系统设置内——App 无公开 API 代理修改，跳转由你亲手完成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            viewModel.openBatterySettings()
                        } label: {
                            Label("去优化充电设置", systemImage: "arrow.up.forward.app")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.blue.opacity(0.18)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func healthText(_ details: BatteryDetails) -> String {
        if let percent = BatteryDetailsMapping.healthPercent(
            maxCapacity: details.maxCapacity,
            designCapacity: details.designCapacity
        ) {
            return "\(percent)%"
        }
        return "—"
    }

    /// 健康度色档借用体检色档的三档色（语义同为 好/中/差），tier 缺测给 .fair 的中性色
    private func healthTierColorProxy(_ details: BatteryDetails) -> HealthScoreTier {
        switch BatteryHealthTier.tier(
            forHealthPercent: BatteryDetailsMapping.healthPercent(
                maxCapacity: details.maxCapacity,
                designCapacity: details.designCapacity
            )
        ) {
        case .normal: return .good
        case .attention: return .fair
        case .replace: return .poor
        case nil: return .fair
        }
    }

    private func optional(_ value: Int?, suffix: String = "") -> String {
        guard let value else { return "—" }
        return "\(value)\(suffix)"
    }
}

// MARK: - 体检报告页（A3·E18，纯展示）

struct HealthReportPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let report = viewModel.healthReport {
                    VStack(spacing: 4) {
                        Text("\(report.score) 分")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(
                                HealthScoreColor.color(for: HealthScoreTier.tier(forScore: report.score))
                            )
                        Text(tierText(HealthScoreTier.tier(forScore: report.score)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                    ForEach(report.results, id: \.id) { result in
                        HealthResultRow(result: result) {
                            viewModel.openRemediation(checkID: result.id)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "stethoscope")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("体检引擎未接入")
                            .font(.callout)
                        Text("主线接入 HealthReportProvider 后此处展示检查结果")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private func tierText(_ tier: HealthScoreTier) -> String {
        switch tier {
        case .good: return "状态良好"
        case .fair: return "有可改进项"
        case .poor: return "建议尽快处理"
        }
    }
}

private struct HealthResultRow: View {
    let result: HealthCheckResult
    let onRemediate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .frame(width: 16)
                Text(result.title).font(.callout)
                Spacer(minLength: 4)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(result.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 23)
            // "去修复"只在确有深链的失败/警告项出现——修不了的不给假按钮
            if !result.remediationHint.isEmpty, showsRemediationButton {
                HStack(spacing: 8) {
                    Text(result.remediationHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(action: onRemediate) {
                        Label("去修复", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.18)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 23)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var showsRemediationButton: Bool {
        PanelDeepLink.remediationURL(forCheckID: result.id) != nil
    }

    private var symbolName: String {
        switch result.status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .notApplicable: return "minus.circle"
        }
    }

    private var symbolColor: Color {
        switch result.status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .notApplicable: return .secondary
        }
    }

    private var statusText: String {
        switch result.status {
        case .pass: return "通过"
        case .warn: return "警告"
        case .fail: return "未通过"
        case .notApplicable: return "不适用"
        }
    }
}

// MARK: - 滚轮捕捉（音量行内滚轮调节，macOS 13 无 SwiftUI onScroll 系列）

/// 透传滚轮事件的 NSView 桥：SwiftUI 的 scroll 手势 API（onScrollGeometryChange 等）要
/// macOS 14+，13 只能走 AppKit scrollWheel。事件在行内就地消费（不调 super），
/// 避免同时驱动外层滚动
struct ScrollWheelCatcher: NSViewRepresentable {
    let onScrollDelta: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(onScrollDelta: onScrollDelta)
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScrollDelta = onScrollDelta
    }

    final class CatcherView: NSView {
        var onScrollDelta: (Double) -> Void = { _ in }

        init(onScrollDelta: @escaping (Double) -> Void) {
            self.onScrollDelta = onScrollDelta
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func scrollWheel(with event: NSEvent) {
            onScrollDelta(event.scrollingDeltaY)
            // 不调 super：滚轮已被音量行消费
        }
    }
}
