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
        case .history: HistoryPage(viewModel: viewModel)
        case .batteryCare: BatteryCarePage(viewModel: viewModel)
        case .plugins: PluginManagerPage(viewModel: viewModel)
        case .updateScan: UpdateScanPage(viewModel: viewModel)
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

// MARK: - 历史查看页（E10/T-207：电池健康曲线 + 事件日志筛选 + CSV 导出）

struct HistoryPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                chartSection
                eventsSection
                exportSection
            }
        }
    }

    // MARK: 曲线区

    @ViewBuilder
    private var chartSection: some View {
        GroupBox("电池健康（每日容量%）") {
            if viewModel.historyDaily.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: PanelRoute.history.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无每日记录")
                        .font(.callout)
                    Text("后台每天记一行电池容量，数天后这里出现趋势曲线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    BatteryHealthChartView(series: viewModel.historyDaily)
                        .frame(height: 120)
                    HStack {
                        Text(firstDateText)
                        Spacer()
                        Text(latestCapacityText)
                        Spacer()
                        Text(lastDateText)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var firstDateText: String {
        viewModel.historyDaily.first?.date ?? ""
    }

    private var lastDateText: String {
        viewModel.historyDaily.last?.date ?? ""
    }

    private var latestCapacityText: String {
        guard let latest = viewModel.historyDaily.last else { return "" }
        return "最新 \(latest.batteryCapacityPercent)%"
    }

    // MARK: 事件区

    private var eventsSection: some View {
        GroupBox("事件日志") {
            VStack(alignment: .leading, spacing: 6) {
                if !viewModel.historyEventKindOptions.isEmpty {
                    Picker("类型", selection: filterBinding) {
                        Text("全部").tag(String?.none)
                        ForEach(viewModel.historyEventKindOptions, id: \.self) { kind in
                            Text(HistoryEventFormatting.kindDisplayName(kind))
                                .tag(String?.some(kind))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                if viewModel.filteredHistoryEvents.isEmpty {
                    Text(
                        viewModel.historyEvents.isEmpty
                            ? "暂无事件记录"
                            : "当前筛选无匹配事件"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.filteredHistoryEvents) { row in
                        HistoryEventRowView(row: row)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Picker 双向绑定：写入走 VM 方法（筛选是页内瞬态，不进设置持久化）
    private var filterBinding: Binding<String?> {
        Binding(
            get: { viewModel.historyEventFilter },
            set: { viewModel.setHistoryEventFilter($0) }
        )
    }

    // MARK: 导出区

    private var exportSection: some View {
        GroupBox("导出") {
            HStack(spacing: 8) {
                Text("把当前筛选的事件导出为 CSV（时间/类型/描述全字段）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    _ = viewModel.exportHistoryCSV()
                } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.up")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.blue.opacity(0.18)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isHistoryExportAvailable || viewModel.filteredHistoryEvents.isEmpty)
                if let succeeded = viewModel.lastHistoryExportSucceeded {
                    Text(succeeded ? "已导出" : "导出未完成")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 自绘容量折线（macOS 13 兼容：Canvas + Path。不引 Swift Charts——一条折线的
/// 包体代价不划算，且固定 y 域 0-100 的口径在 HistoryChartMapping 纯函数里可测）。
/// 80% 虚线参考 = BatteryHealthTier.attention 门限，曲线一眼对齐"注意"线
struct BatteryHealthChartView: View {
    let series: [DailyMetricPoint]

    var body: some View {
        Canvas { context, size in
            let points = HistoryChartMapping.capacityPoints(series, size: size)
            guard !points.isEmpty else { return }
            if let referenceY = HistoryChartMapping.referenceLineY(atPercent: 80, height: size.height) {
                let reference = Path { path in
                    path.move(to: CGPoint(x: 0, y: referenceY))
                    path.addLine(to: CGPoint(x: size.width, y: referenceY))
                }
                context.stroke(
                    reference,
                    with: .color(.secondary.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )
            }
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() {
                line.addLine(to: point)
            }
            context.stroke(
                line,
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
            )
            for point in [points.first, points.last] {
                guard let point else { continue }
                let dot = Path(
                    ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                )
                context.fill(dot, with: .color(.accentColor))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.25))
        )
    }
}

/// 单事件行：类型图标 + 名称/描述 + 时间（新在前，倒序由 VM 保证）
struct HistoryEventRowView: View {
    let row: EventRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: HistoryEventFormatting.symbolName(for: row.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(HistoryEventFormatting.kindDisplayName(row.kind))
                    .font(.callout)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(HistoryEventFormatting.timeText(iso: row.at))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

// MARK: - 电池养护页（E13/T-212：充电上限/优化充电状态行 + 健康曲线 + 月度小结）

struct BatteryCarePage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                overviewSection
                chartSection
                monthlySection
            }
        }
    }

    // MARK: 养护总览（充电域只读；上限读不到是 macOS 现状，如实降级）

    private var overviewSection: some View {
        GroupBox("养护总览") {
            VStack(alignment: .leading, spacing: 0) {
                if let details = viewModel.batteryDetail {
                    DetailLine(
                        title: "健康度",
                        value: healthText(details),
                        valueColor: careHealthColor(details)
                    )
                    DetailLine(title: "循环次数", value: details.cycleCount.map(String.init) ?? "—")
                    DetailLine(
                        title: "充电状态",
                        value: BatteryCareMapping.chargingStateText(
                            externalConnected: details.externalConnected,
                            isCharging: details.isCharging
                        ),
                        valueColor: details.isCharging ? Color.green : Color.primary
                    )
                } else {
                    Text("未读到电池信息（台式机无 AppleSmartBattery，或详情读取服务未接入）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                DetailLine(title: "充电上限", value: BatteryCareMapping.chargeLimitMissingText)
                Text(BatteryCareMapping.chargeLimitExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("优化充电的开关也在系统设置内（学习充电习惯、暂缓充满）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        viewModel.openBatterySettings()
                    } label: {
                        Label("去电池设置", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.18)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 健康曲线（复用 T-207 折线与 80% 参考线口径）

    private var chartSection: some View {
        GroupBox("电池健康（每日容量%）") {
            let points = BatteryCareMapping.chartPoints(from: viewModel.careDaily)
            if points.isEmpty {
                Text("暂无每日记录——后台每天记一行，数天后这里出现趋势曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    BatteryHealthChartView(series: points)
                        .frame(height: 110)
                    HStack {
                        Text(points.first?.date ?? "")
                        Spacer()
                        if let latest = points.last {
                            Text("最新 \(latest.batteryCapacityPercent)%")
                        }
                        Spacer()
                        Text(points.last?.date ?? "")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 月度小结（E10 metric_daily 聚合）

    private var monthlySection: some View {
        GroupBox("月度小结") {
            if viewModel.careMonthly.isEmpty {
                Text("暂无月度数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                // 新月份在前（用户最关心最近一个月）
                ForEach(viewModel.careMonthly.reversed()) { summary in
                    CareMonthlyRow(summary: summary)
                }
            }
        }
    }

    private func healthText(_ details: BatteryDetails) -> String {
        BatteryDetailsMapping.healthPercent(
            maxCapacity: details.maxCapacity,
            designCapacity: details.designCapacity
        ).map { "\($0)%" } ?? "—"
    }

    private func careHealthColor(_ details: BatteryDetails) -> Color {
        switch BatteryHealthTier.tier(
            forHealthPercent: BatteryDetailsMapping.healthPercent(
                maxCapacity: details.maxCapacity,
                designCapacity: details.designCapacity
            )
        ) {
        case .normal: return .green
        case .attention: return .orange
        case .replace: return .red
        case nil: return .primary
        }
    }
}

/// 单月小结行：月份标题行 + 三项指标（均值/增减/充电次数）
private struct CareMonthlyRow: View {
    let summary: CareMonthlySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(summary.monthKey)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text("记录 \(summary.recordedDays) 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("充电 \(summary.chargeStartCount) 次")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Text("容量均值 \(summary.averageCapacityPercent.map { "\($0)%" } ?? "—")")
                if let delta = summary.capacityDelta {
                    Text("容量 \(delta >= 0 ? "+" : "")\(delta)%")
                        .foregroundStyle(delta < 0 ? Color.orange : Color.secondary)
                } else {
                    Text("容量 —")
                        .foregroundStyle(.secondary)
                }
                if let cycle = summary.cycleDelta {
                    Text("循环 +\(cycle)")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - 插件管理页（E16·SP-03/T-213：扫描列表 + 健康状态 + 重载 + 三连击说明）

struct PluginManagerPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.pluginRows.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "puzzlepiece")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("未发现有效插件")
                            .font(.callout)
                        Text("把 manifest.json + script.sh 放进 ~/Library/Application Support/StatusButler/plugins/<目录>/ 后回来重扫")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    ForEach(viewModel.pluginRows) { row in
                        PluginManagerRow(row: row) {
                            viewModel.reloadPlugin(row.id)
                        }
                    }
                }
                Text(PluginPanelMapping.tripleStrikeExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }
}

/// 单插件行：manifest 字段 + 健康徽标 + 重载按钮
private struct PluginManagerRow: View {
    let row: PluginRowState
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.callout)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            healthBadge
            Button(action: onReload) {
                Label(PluginPanelMapping.needsReset(row.health) ? "重载并复位" : "重载",
                      systemImage: "arrow.clockwise")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var subtitle: String {
        var parts = ["\(URL(fileURLWithPath: row.interpreter).lastPathComponent) · \(row.refreshHintSeconds)s"]
        if let author = row.author, !author.isEmpty {
            parts.append(author)
        }
        if row.failureCount > 0 {
            parts.append("连败 \(row.failureCount)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var healthBadge: some View {
        let (color, text) = badgePair
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }

    private var badgePair: (Color, String) {
        switch row.health {
        case .healthy: return (.green, "正常")
        case .degraded: return (.orange, "连败中")
        case .stopped: return (.red, "已停用")
        }
    }
}

// MARK: - 更新扫描页（E25·UPDT-01/T-221：比对结果 + 官网深链，纯提示不代装）

struct UpdateScanPage: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.checkForUpdates()
                    } label: {
                        HStack(spacing: 5) {
                            if viewModel.isUpdateScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(viewModel.isUpdateScanning ? "检查中…" : "重新检查")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isUpdateScanning)
                    Spacer()
                    Text(viewModel.updateScanSummary ?? "比对 Homebrew cask 数据源，只提示不代装")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if viewModel.updateResults.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: PanelRoute.updateScan.symbolName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(emptyText)
                            .font(.callout)
                        Text("扫描本地 brew cask 清单并比对官方 API 版本；三道网络闸（https+域名白名单/DNS 全公网/同域重定向）与天气域同纪律")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    ForEach(viewModel.updateResults) { update in
                        UpdateScanRow(update: update) {
                            viewModel.openCaskHomepage(update)
                        }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        viewModel.isUpdateScanning ? "正在读取本地清单并比对…" : "尚无结果，点「重新检查」开始"
    }
}

/// 单 cask 结果行：名字 + 版本走向 + 可更新徽标 + 官网深链
private struct UpdateScanRow: View {
    let update: CaskUpdate
    let onOpenHomepage: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.name).font(.callout)
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if update.isOutdated == true {
                Text("可更新")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .foregroundStyle(.orange)
            } else if update.isOutdated == nil {
                Text("无法比对")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if update.homepageURL != nil {
                Button(action: onOpenHomepage) {
                    Label("官网", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.18)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private var versionText: String {
        switch (update.installedVersion, update.latestVersion) {
        case let (local?, latest?):
            return local == latest ? "已装 \(local)" : "已装 \(local) → 最新 \(latest)"
        case let (nil, latest?):
            return "本地版本未知 · 最新 \(latest)"
        case let (local?, nil):
            return "已装 \(local) · 远端版本未知"
        default:
            return "版本未知"
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
