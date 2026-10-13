import AppKit
import Combine
import SwiftUI

// MARK: - 外接屏亮度面板（T-214c · A11 E14 DDC 面板 + 昼夜自动调光）
//
// 控制器持有真 DDCClient 与调光引擎，全部 IO 走闭包注入面（同 ThemePortController
// 纪律：构造零窗口依赖、CI 不实例化即可安全）。DDC 不可用/无外接屏 → 整区只显示
// 引导文案（DDC-04 静默降级，绝不弹窗）。

/// 外接屏默认昼夜调光规则：日 80 / 夜 30，07:00-19:00 为日间——
/// 数值口径与系统自动亮度的观感档对齐，属产品默认而非用户配置（T-214 简化范围）
public enum ExternalBrightnessDefaults {
    public static let rule = DaylightBrightnessRule(
        dayValue: 80, nightValue: 30, sunriseAt: 7, sunsetAt: 19
    )
}

@MainActor
public final class ExternalBrightnessController: ObservableObject {
    @Published public private(set) var displays: [DDCDisplay] = []
    /// 每屏滑杆值（DDC 读不到时由映射回落 50 起步）
    @Published public private(set) var levels: [UInt64: Double] = [:]

    private let wiring: DaylightBrightnessController.Wiring
    private let ddcIsAvailable: Bool
    private let dimmer: DaylightBrightnessController
    private var appearanceObserver: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var didBind = false

    private init(
        wiring: DaylightBrightnessController.Wiring,
        ddcIsAvailable: Bool,
        hour: @escaping () -> Double
    ) {
        self.wiring = wiring
        self.ddcIsAvailable = ddcIsAvailable
        self.dimmer = DaylightBrightnessController(wiring: wiring, hour: hour)
    }

    public convenience init(
        wiring: DaylightBrightnessController.Wiring = .live(),
        hour: @escaping () -> Double = {
            Double(Calendar.current.component(.hour, from: Date()))
                + Double(Calendar.current.component(.minute, from: Date())) / 60
        }
    ) {
        self.init(wiring: wiring, ddcIsAvailable: true, hour: hour)
    }

    /// 测试注入面：ddcIsAvailable=false 复现"符号缺失整域降级"的 UI 分支
    public convenience init(unavailable: Bool) {
        self.init(
            wiring: .init(
                displays: { [DDCDisplay]() },
                readBrightness: { _ in nil },
                writeBrightness: { _, _ in false }
            ),
            ddcIsAvailable: !unavailable,
            hour: { 12 }
        )
    }

    public var isDDCAvailable: Bool { ddcIsAvailable }

    /// 枚举 + 读当前亮度（面板出现/刷新按钮）：读失败按映射回落值展示
    public func refresh() {
        guard ddcIsAvailable else {
            displays = []
            levels = [:]
            return
        }
        displays = wiring.displays()
        levels = displays.reduce(into: [:]) { map, display in
            map[display.id] = DDCBrightnessMapping.sliderValue(fromDDC: wiring.readBrightness(display))
        }
    }

    /// 滑杆拖动：值经映射钳制后直写该屏——用户拖动本身已是连续渐变，无需再叠 BrightnessRamp
    public func setLevel(_ raw: Double, on display: DDCDisplay) {
        let value = DDCBrightnessMapping.ddcValue(fromSlider: raw)
        levels[display.id] = Double(value)
        _ = wiring.writeBrightness(value, display)
    }

    /// 开关联动：开 → 立即按当前昼夜求值一次 + KVO 外观变化再求值；
    /// 关 → 撤观察（已写进显示器的亮度不回滚——自动调光不是独占权）。
    /// 幂等：视图 .task 重入只绑一次
    public func bind(to settings: SettingsStore) {
        guard !didBind else { return }
        didBind = true
        settings.$autoBrightness
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.startAutoDimming()
                } else {
                    self?.stopAutoDimming()
                }
            }
            .store(in: &cancellables)
        if settings.autoBrightness { startAutoDimming() }
    }

    private func startAutoDimming() {
        guard ddcIsAvailable, appearanceObserver == nil else { return }
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance, options: [.initial, .new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // 触发=外观变化；目标值由规则按当前小时求值（引擎头注释的口径分工）
                Task { @MainActor [weak self] in await self?.dimmer.reevaluate(rule: ExternalBrightnessDefaults.rule) }
            }
        }
    }

    private func stopAutoDimming() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
    }
}

// MARK: - 面板区块（AppearancePane "外接显示器"区）

public struct ExternalDisplaySection: View {
    @ObservedObject private var settings: SettingsStore
    @StateObject private var controller: ExternalBrightnessController

    public init(settings: SettingsStore) {
        self.settings = settings
        _controller = StateObject(wrappedValue: ExternalBrightnessController())
    }

    public var body: some View {
        Section {
            if controller.isDDCAvailable {
                if controller.displays.isEmpty {
                    Text("未发现支持 DDC/CI 的外接显示器（内建屏亮度请用系统控制中心）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.displays, id: \.id) { display in
                        PreferenceRow(
                            "显示器 #\(display.id % 1000)",
                            subtitle: "DDC/CI 亮度（0-100）"
                        ) {
                            Slider(
                                value: Binding(
                                    get: { controller.levels[display.id] ?? 50 },
                                    set: { controller.setLevel($0, on: display) }
                                ),
                                in: 0...100,
                                step: 1
                            ) {
                                Text("亮度")
                            } minimumValueLabel: {
                                Text("0")
                            } maximumValueLabel: {
                                Text("100")
                            }
                            .frame(width: 200)
                        }
                    }
                }
                PreferenceCheckboxRow(
                    "昼夜自动调光",
                    subtitle: "跟随系统明暗外观，在日间 80 / 夜间 30 间渐变（07:00-19:00 为日间）",
                    isOn: $settings.autoBrightness
                )
                .disabled(controller.displays.isEmpty)
            } else {
                // dlsym 失败类环境（理论罕见）：如实降级展示，功能不假装可用
                Text("此系统不支持 DDC/CI 通道，外接屏亮度功能不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("外接显示器")
        } footer: {
            Text("仅外接屏经 DDC/CI 控制；内建屏亮度属系统能效域，本应用不介入。")
        }
        .task {
            controller.refresh()
            controller.bind(to: settings)
        }
    }
}
