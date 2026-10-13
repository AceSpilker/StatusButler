import AppKit
import SwiftUI

// T-031 / A2·S9·OG-FR-180：设置中心窗口与四分区。
// 边界：本文件只建新 UI，不改既有装配——窗口由集成方在菜单栏菜单挂"设置…"入口调
// SettingsWindowController.showWindow(_:)（S9 后续任务或集成提交完成）。

// MARK: - 窗口控制器

/// 设置窗口壳：NSWindow 承载 SwiftUI 内容。
/// 导航选 NavigationSplitView 侧栏式而非 NSToolbar 分段控件：
/// 1) macOS 13 起 System Settings 即侧栏范式，分段控件是 iOS 偏好面板形态；
/// 2) 选中态、面板切换全部留在 SwiftUI @State 内，无需手写 NSToolbar item 同步；
/// 3) 分区后续要增长到 S9 全量 9 分区，侧栏可滚动、分段控件放不下。
@MainActor
public final class SettingsWindowController {
    private let window: NSWindow
    private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
        // miniaturizable 留着：设置窗虽小，用户拖走/最小化的习惯不该被剥夺
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false   // 开关复用同一窗口，设置态（含侧栏选中）不丢
        window.setFrameAutosaveName("StatusButlerSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsRootView(settings: settings))
        window.center()
    }

    public func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(sender)
    }
}

// MARK: - 根视图（侧栏 + 详情）

public struct SettingsRootView: View {
    @ObservedObject private var settings: SettingsStore
    @State private var selection: SettingsPane.ID?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            // 选中态被系统清空（如键盘导航边界）时回落到通用，详情区永不满屏空白
            paneView(selection ?? SettingsPane.general.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selection.map { SettingsPane(rawValue: $0)?.title ?? "" } ?? "通用")
        }
        .onAppear { if selection == nil { selection = SettingsPane.general.id } }
        .frame(minWidth: 560, minHeight: 400)
    }

    @ViewBuilder
    private func paneView(_ paneID: String) -> some View {
        switch SettingsPane(rawValue: paneID) {
        case .general: GeneralPane(settings: settings)
        case .appearance: AppearancePane(settings: settings)
        case .panel: PanelPane(settings: settings)
        case .hotkey: HotKeyPane(settings: settings)
        case .about: AboutPane(settings: settings)
        case nil: GeneralPane(settings: settings)
        }
    }
}

// MARK: - 通用分区

public struct GeneralPane: View {
    @ObservedObject private var settings: SettingsStore
    /// 城市搜索框草稿：过滤是纯函数现算（WeatherCityCatalog.search），不落盘
    @State private var cityQuery = ""

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                // 语言切换（OG-FR-191）：appLanguage didSet 落盘 + languageVersion 信号驱动本页重算
                PreferenceRow(l10n(.settingsLanguage), subtitle: l10n(.settingsLanguageEffect)) {
                    Picker(l10n(.settingsLanguage), selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(settings.localization.string(language.titleKey))
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferenceRow("刷新间隔", subtitle: "监控器采样周期；调小更实时、更耗电") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.refreshIntervalSeconds) },
                            set: { settings.refreshIntervalSeconds = Int($0.rounded()) }
                        ),
                        in: Double(SettingsStore.refreshIntervalRange.lowerBound)...Double(SettingsStore.refreshIntervalRange.upperBound),
                        step: 1
                    ) {
                        Text("刷新间隔")
                    } minimumValueLabel: {
                        Text("\(SettingsStore.refreshIntervalRange.lowerBound) 秒")
                    } maximumValueLabel: {
                        Text("\(SettingsStore.refreshIntervalRange.upperBound) 秒")
                    }
                    .frame(width: 220)
                }
                PreferenceRow("当前间隔", subtitle: nil) {
                    Text("\(settings.refreshIntervalSeconds) 秒")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // 开机自启动（A2·S2）：SMAppService 注册/注销由 SettingsStore.didSet 驱动；
                // 非 .app 宿主（swift run）系统无法管理登录项，开关禁用保诚实
                PreferenceCheckboxRow(
                    l10n(.settingsLaunchAtLogin),
                    subtitle: l10n(.settingsLaunchAtLoginSubtitle),
                    isOn: $settings.launchAtLogin
                )
                .disabled(!settings.isLoginItemSupported)
                if settings.loginItemStatus == .requiresApproval {
                    PreferenceRow(l10n(.loginItemRequiresApproval), subtitle: nil) {
                        Button(l10n(.loginItemOpenSettings)) {
                            settings.openLoginItemsSettings()
                        }
                    }
                }
                // 遥测三态（OG-FR-201 默认关）：未设置态显式可见，提示用户决策过
                PreferenceRow(l10n(.settingsTelemetry), subtitle: nil) {
                    Picker(l10n(.settingsTelemetry), selection: $settings.telemetryConsent) {
                        ForEach(TelemetryConsent.allCases, id: \.self) { consent in
                            Text(l10n(consent.localizationKey))
                                .tag(consent)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("iCloud 同步") {
                // T-219 / E8：默认关。开关只落偏好——开机装配（LiveServices）读它决定
                // 是否挂同步协调器；面板状态行如实报告容器可用性（检测不轮询，出现即探一次）
                PreferenceCheckboxRow(
                    "同步设置与主题",
                    subtitle: "范围：设置 + 主题两块 JSON，经 iCloud 私有库（默认关）",
                    isOn: $settings.iCloudSyncEnabled
                )
                iCloudStatusRow()
            }
            Section("天气") {
                // T-201 / A8·WX-01：默认手动城市。未配置 = 天气静默（不取数不报错），
                // 槽位里只显示降级文案；配置后 WeatherFeed 按 30 分钟节拍取数（集成注记见 WeatherCityCatalog.swift 头）
                PreferenceRow(
                    "天气城市",
                    subtitle: settings.weatherCity.map { "当前：\($0)" } ?? "未配置（天气保持静默）"
                ) {
                    if let city = settings.weatherCity,
                       let entry = WeatherCityCatalog.city(named: city) {
                        Text(String(format: "%.2f°N, %.2f°E", abs(entry.latitude), abs(entry.longitude)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("不使用天气") {
                        settings.weatherCity = nil
                        cityQuery = ""
                    }
                    .disabled(settings.weatherCity == nil)
                }
                PreferenceRow("搜索城市", subtitle: "中文名或拼音，前缀/包含匹配；选择后立即生效") {
                    TextField("如：杭州 或 hang", text: $cityQuery)
                        .frame(maxWidth: 240)
                }
                // 命中列表：上限 8 条防长表把分区撑爆；点击即选中并清空搜索（选完即走的操作路径）
                let matches = WeatherCityCatalog.search(cityQuery).prefix(8)
                ForEach(Array(matches)) { city in
                    Button {
                        settings.weatherCity = city.name
                        cityQuery = ""
                    } label: {
                        HStack {
                            Text(city.name)
                            if settings.weatherCity == city.name {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            Text(city.pinyin)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func l10n(_ key: LocalizationKey) -> String {
        settings.localization.string(key)
    }
}

/// iCloud 容器状态行（T-219）：出现即探一次 + 手动"重新检测"，检测中禁按钮防连点。
/// 降级文案走 ICloudSyncStatus.message 纯映射，含"缺 entitlements/容器未建"的清单指引
private struct iCloudStatusRow: View {
    @State private var status = ICloudSyncStatus.checking

    var body: some View {
        PreferenceRow("容器状态", subtitle: status.message) {
            Button("重新检测") {
                status = .checking
                Task { status = await ICloudAvailability.probe() }
            }
            .disabled(status == .checking)
        }
        .task { status = await ICloudAvailability.probe() }
    }
}

/// 三态 → 展示文案键（设置页专用映射；键集合在 Localization 单点登记）
private extension TelemetryConsent {
    var localizationKey: LocalizationKey {
        switch self {
        case .notAsked: .telemetryNotAsked
        case .optedIn: .telemetryOptedIn
        case .optedOut: .telemetryOptedOut
        }
    }
}

// MARK: - 状态图标外观分区

public struct AppearancePane: View {
    @ObservedObject private var settings: SettingsStore
    /// 导入导出编排器：面板/文件 IO 全注入，@StateObject 与本视图同生命周期
    /// （默认闭包只在按钮动作里触达 NSOpenPanel/NSSavePanel，构造零窗口依赖，CI 安全）
    @StateObject private var port = ThemePortController()

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("实时预览") {
                IconPreviewCard(settings: settings)
            }
            Section("图标") {
                PreferenceRow("图标大小", subtitle: "菜单栏图标边长（pt）") {
                    Slider(
                        value: $settings.menuBarIconSize,
                        in: SettingsStore.iconSizeRange,
                        step: 1
                    ) {
                        Text("图标大小")
                    } minimumValueLabel: {
                        Text("\(Int(SettingsStore.iconSizeRange.lowerBound))")
                    } maximumValueLabel: {
                        Text("\(Int(SettingsStore.iconSizeRange.upperBound))")
                    }
                    .frame(width: 220)
                }
                PreferenceRow("当前大小", subtitle: nil) {
                    Text("\(Int(settings.menuBarIconSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                PreferenceCheckboxRow("显示电池百分比", subtitle: "低电时菜单栏图标外的文字提示策略", isOn: $settings.showsBatteryPercentage)
            }
            Section("底部槽位") {
                PreferenceRow("槽位内容", subtitle: "显示在状态面板底部的辅助信息源") {
                    Picker("槽位内容", selection: $settings.footerSlotID) {
                        ForEach(SettingsSlotOptions.all) { option in
                            // 占位源可先选中（持久化合法，数据源接入即点亮），文本标注管理预期
                            Text(option.isPending ? "\(option.title)（待数据源）" : option.title)
                                .tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                // T-220 / E24：默认关。皮肤挂在三个文本槽（时钟/磁盘/电池%）上，
                // 帧驱动与渲染接线见 StatusIconRenderer 侧 TODO（充电时钟节拍）
                PreferenceRow("趣味皮肤", subtitle: "底槽文本旁的小动画（CPU 负载驱动帧率，默认关）") {
                    Picker("趣味皮肤", selection: $settings.animatedSkin) {
                        Text("关闭").tag(String?.none)
                        Text("跑猫").tag(String?.some(AnimatedSkinCatalog.runningCatID))
                        Text("游鱼").tag(String?.some(AnimatedSkinCatalog.swimmingFishID))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("主题") {
                // T-208：导入前差异预览、应用后跳过项可见（E7·TH-03/05），导出是当前配置的快照
                PreferenceRow("导入 / 导出", subtitle: ".butler-theme 主题文件（JSON）") {
                    HStack {
                        Button("导入…") { port.beginImport(from: settings) }
                        Button("导出…") { port.export(from: settings) }
                    }
                }
                importFeedback
                exportFeedback
            }
            // T-214 / E23：昼夜主题——跟随系统明暗外观在两套预设间切（默认关）。
            // 集成注记（主线接线）：组合根（LiveServices.start）构造
            // DaylightSwitcher(settings:).start() 即全 App 生效，本页只改设置不持实例
            Section("昼夜主题") {
                PreferenceCheckboxRow(
                    "跟随系统外观切换",
                    subtitle: "系统外观变亮/变暗时自动应用对应预设（默认关）",
                    isOn: $settings.autoDaylightTheme
                )
                PreferenceRow("日间主题", subtitle: "系统外观为亮色时应用") {
                    Picker("日间主题", selection: $settings.daylightTheme) {
                        ForEach(ThemePresets.all.keys.sorted(), id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PreferenceRow("夜间主题", subtitle: "系统外观为暗色时应用") {
                    Picker("夜间主题", selection: $settings.dayNightTheme) {
                        ForEach(ThemePresets.all.keys.sorted(), id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            // T-214 / E14：外接屏 DDC 亮度滑杆 + 昼夜自动调光（默认关）
            ExternalDisplaySection(settings: settings)
        }
    }

    @ViewBuilder
    private var importFeedback: some View {
        switch port.importPhase {
        case .idle:
            EmptyView()
        case .previewing(let rows):
            // 差异预览表：字段/现值/新值——用户确认的是"将发生什么"，不是盲应用
            VStack(alignment: .leading, spacing: 6) {
                Text("导入预览（\(rows.count) 项变更）")
                    .font(.callout.weight(.medium))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow {
                        Text("字段")
                        Text("现值")
                        Text("新值")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.field)
                            Text(row.currentValue)
                                .foregroundStyle(.secondary)
                            Text(row.newValue)
                        }
                        .font(.caption)
                    }
                }
                HStack {
                    Button("确认应用") { port.confirmImport(to: settings) }
                        .buttonStyle(.borderedProminent)
                    Button("取消") { port.reset() }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        case .applied(let skipped):
            VStack(alignment: .leading, spacing: 6) {
                Label("主题已应用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if skipped.isEmpty {
                    Text("全部字段生效，无跳过项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // TH-05：跳过项必须可读，不静默吞
                    Text("以下 \(skipped.count) 项未生效：")
                        .font(.caption)
                    ForEach(skipped, id: \.self) { note in
                        Text("· \(note)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("好") { port.reset() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("导入失败", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("好") { port.reset() }
            }
        }
    }

    @ViewBuilder
    private var exportFeedback: some View {
        switch port.exportOutcome {
        case .idle:
            EmptyView()
        case .saved(let path):
            VStack(alignment: .leading, spacing: 4) {
                Label("已导出", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("好") { port.dismissExportNotice() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("导出失败", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("好") { port.dismissExportNotice() }
            }
        }
    }
}

// MARK: - 状态面板分区

/// 布局编辑纯函数（T-209）：显隐与排序都产出新 PanelLayout 值，Store 写入即持久化。
/// 排序只动 order（全量排列），显隐只动 visibleSections（order 的子集）——两条不变量
/// 由 PanelLayout.isValid/sanitized 兜底，本层不另设校验
public enum PanelLayoutEditor {
    /// 上移/下移：offset 取 ±1（按钮语义），目标越界原样返回（首行上移=无操作）。
    /// 泛化成任意 offset 是为了测试可直跳多步，UI 只用 ±1
    public static func move(_ layout: PanelLayout, id: PanelSectionID, offset: Int) -> PanelLayout {
        guard let index = layout.order.firstIndex(of: id) else { return layout }
        let target = index + offset
        guard layout.order.indices.contains(target), target != index else { return layout }
        var order = layout.order
        order.swapAt(index, target)
        return PanelLayout(visibleSections: layout.visibleSections, order: order)
    }

    /// 显隐切换：隐藏=从 visibleSections 移除；显示=追加（visible 是集合语义，
    /// 追加位置不影响面板渲染——渲染按 order 过滤 visible）
    public static func setVisible(_ layout: PanelLayout, id: PanelSectionID, visible: Bool) -> PanelLayout {
        var visibleSections = layout.visibleSections
        if visible {
            if !visibleSections.contains(id) { visibleSections.append(id) }
        } else {
            visibleSections.removeAll { $0 == id }
        }
        return PanelLayout(visibleSections: visibleSections, order: layout.order)
    }
}

public struct PanelPane: View {
    @ObservedObject private var settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("充电指示") {
                PreferenceCheckboxRow(
                    "充电动画",
                    subtitle: "充电时图标外圈呼吸光效；系统\"减弱动态\"时自动关闭",
                    isOn: $settings.showsChargingEffect
                )
            }
            // T-209：分区排序编辑器。状态源唯一（SettingsStore.panelLayout），
            // 本视图经 PanelLayoutEditor 纯函数产新值写回；LiveServices 构造 PanelViewModel
            // 时传 settings.panelLayout 即点亮（集成注记见 section 尾注释）
            Section {
                ForEach(Array(settings.panelLayout.order.enumerated()), id: \.element) { index, section in
                    HStack {
                        Label(section.displayName, systemImage: section.symbolName)
                        Spacer(minLength: 16)
                        Toggle("显示", isOn: Binding(
                            get: { settings.panelLayout.visibleSections.contains(section) },
                            set: { settings.panelLayout = PanelLayoutEditor.setVisible(settings.panelLayout, id: section, visible: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("取消勾选后该分区从状态面板隐藏（数据采样随弹层显隐启停，不受此项影响）")
                        Button {
                            settings.panelLayout = PanelLayoutEditor.move(settings.panelLayout, id: section, offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("上移")
                        Button {
                            settings.panelLayout = PanelLayoutEditor.move(settings.panelLayout, id: section, offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == settings.panelLayout.order.count - 1)
                        .help("下移")
                    }
                }
                if settings.panelLayout.visibleSections.isEmpty {
                    Text("所有分区已隐藏：弹层将只剩标题与底槽。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("分区排序与显隐")
            } footer: {
                Text("列表顺序即弹层分区顺序。")
            }
            Section("槽位轮换") {
                // 占位：多槽位轮换展示随 A8·SL-05 接入（依赖槽位调度器）
                PreferenceCheckboxRow("底部槽位自动轮换", subtitle: "待槽位调度器（A8·SL-05）接入", isOn: .constant(false))
                    .disabled(true)
            }
            // 集成注记（T-209 主线接线）：LiveServices.swift 构造 PanelViewModel 处
            // （panelViewModel = PanelViewModel(…)）补 layout 入参：
            //     panelViewModel = PanelViewModel(store: store, layout: settings.panelLayout, …)
            // 并订阅 settings.$panelLayout.removeDuplicates().sink { vm.apply(layout: $0) }
            // （apply 已是 PanelViewModel 公开方法），设置页改序即时生效。
        }
    }
}

// MARK: - 关于分区

public struct AboutPane: View {
    /// 发布仓库地址由集成/发布任务替换为真实 URL；先占位保证链接控件版式完整
    private static let repositoryURL = URL(string: "https://github.com/linzhongyang/mactool")!

    private let settings: SettingsStore

    // T-055：更新接线状态走 @State + .task 而非属性初始化器持单例——
    // View 属性初始化在非隔离上下文执行，取 @MainActor 的 UpdaterController.shared 会破隔离；
    // body/.task 天然主隔离，合法访问点
    @State private var updateConfigured = false
    @State private var canCheckForUpdates = false
    // 占位域被拦时给出可见说明（fail-visible）——按钮不再是哑的，点击有反馈
    @State private var blockedNoticeVisible = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("状态管家 StatusButler") {
                PreferenceRow("版本", subtitle: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
                    Text("v\(version)")
                        .foregroundStyle(.secondary)
                }
                PreferenceRow("源代码仓库", subtitle: "问题反馈与版本发布") {
                    Link("GitHub ↗", destination: Self.repositoryURL)
                }
                PreferenceRow("软件更新", subtitle: updateConfigured ? "Sparkle 自动更新（EdDSA 签名）" : "更新通道未开通（上线后启用）") {
                    Button("检查更新…") {
                        // 裁决纯函数化：被拦时亮说明而非无声（Sparkle 检查中的重入由 disabled 防）
                        switch UpdateCheckDecision.resolve(
                            isConfigured: updateConfigured,
                            canCheckForUpdates: canCheckForUpdates
                        ) {
                        case .check:
                            UpdaterController.shared.checkNow()
                        case .blocked:
                            blockedNoticeVisible = true
                        }
                    }
                    // 仅"已配置但 Sparkle 正在检查"禁用防重入；未配置保持可点以给出说明
                    .disabled(updateConfigured && !canCheckForUpdates)
                }
                if blockedNoticeVisible && !updateConfigured {
                    Text(l10n(.updateChannelBlocked))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // TODO(T-055 上线): SUFeedURL/SUPublicEDKey 换真值 + appcast 发布后，
                // 更新说明按语言分发与失败降级驱动（OG-FR-200）在此扩展
                // 占位：第三方依赖与开源致谢清单随首个对外发布版本整理
                PreferenceRow("开源致谢", subtitle: "致谢清单整理中") {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let updater = UpdaterController.shared
            updateConfigured = updater.feedInfo.isConfigured
            canCheckForUpdates = updater.canCheckForUpdates
            for await flag in updater.$canCheckForUpdates.values {
                canCheckForUpdates = flag
            }
        }
    }

    private func l10n(_ key: LocalizationKey) -> String {
        settings.localization.string(key)
    }
}
