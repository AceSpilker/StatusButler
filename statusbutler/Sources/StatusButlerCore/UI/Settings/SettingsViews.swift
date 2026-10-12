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
        case .about: AboutPane()
        case nil: GeneralPane(settings: settings)
        }
    }
}

// MARK: - 通用分区

public struct GeneralPane: View {
    @ObservedObject private var settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                // 占位：本地化键外置与语言切换随 OG-FR-191 落地，届时换 Menu + Bundle 资源
                PreferenceRow("App 语言", subtitle: "多语言随本地化任务启用") {
                    Picker("App 语言", selection: .constant("zh-Hans")) {
                        Text("简体中文（默认）").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(true)
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
                // 占位：SMAppService.MainApp 登录项注册随启动任务接入
                PreferenceCheckboxRow("开机自动启动", subtitle: "登录项注册待接入", isOn: .constant(false))
                    .disabled(true)
            }
        }
    }
}

// MARK: - 状态图标外观分区

public struct AppearancePane: View {
    @ObservedObject private var settings: SettingsStore

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
            }
        }
    }
}

// MARK: - 状态面板分区

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
            Section("槽位轮换") {
                // 占位：多槽位轮换展示随 A8·SL-05 接入（依赖槽位调度器）
                PreferenceCheckboxRow("底部槽位自动轮换", subtitle: "待槽位调度器（A8·SL-05）接入", isOn: .constant(false))
                    .disabled(true)
            }
            // TODO(T-031 后续)：分区显隐 + 上移/下移排序。
            // 依赖 PanelLayout 类型（agent/popover 分支，未合并）——合入前不在此另建
            // 第二份分区顺序状态源（架构铁律：设置单一状态源 SettingsStore），届时
            // 新增 @Published panelLayout 字段并在此补 List + onMove 排序 UI。
        }
    }
}

// MARK: - 关于分区

public struct AboutPane: View {
    /// 发布仓库地址由集成/发布任务替换为真实 URL；先占位保证链接控件版式完整
    private static let repositoryURL = URL(string: "https://github.com/linzhongyang/mactool")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    public init() {}

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
                // 占位：第三方依赖与开源致谢清单随首个对外发布版本整理
                PreferenceRow("开源致谢", subtitle: "致谢清单整理中") {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
