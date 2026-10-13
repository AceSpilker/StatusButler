import AppKit
import Combine
import Foundation

// MARK: - 昼夜主题切换器（T-214b · E23）
//
// 简化口径：跟随系统明暗外观（NSApp.effectiveAppearance）而非本地日出日落——
// 系统外观本身就是用户/排程（macOS 自动外观切换已内建日出日落感知）对昼夜的裁决，
// 自算太阳时属于重复造且要定位权限（隐私最小化红线），故只跟随不计算。
// 日出/日落公式（SunriseSunsetCalculator 类）将来若接入，替换 readPhase 的注入源即可。

/// 明暗相位：DaylightSwitcher 的唯一驱动输入
public enum DaylightPhase: String, Equatable, Sendable {
    case light
    case dark

    /// 外观名 → 相位（纯函数，测试钉死）：按 NSAppearance 名约定串判暗色；
    /// 未知名/本地化变体一律按亮色兜底——错切夜间主题比错切日间更扰人（暗环境刺眼）
    public static func from(appearanceName: String) -> DaylightPhase {
        appearanceName.contains("Dark") ? .dark : .light
    }

    /// live 注入源（NSApp 在无 App 壳环境可能为 nil，按亮色兜底保证纯函数性）
    @MainActor
    public static func currentSystemPhase() -> DaylightPhase {
        guard let appearance = NSApp?.effectiveAppearance else { return .light }
        let name = appearance.bestMatch(from: [
            NSAppearance.Name.darkAqua, NSAppearance.Name.aqua,
        ]) ?? .aqua
        return from(appearanceName: name.rawValue)
    }
}

/// 开关开启时按相位把对应预设经 ThemeApplier 落进 store（与应用主题导入同一出口，
/// 保证"自动切换"与"手动应用"行为一致）。关 → 静默不动作；预设键查不到 → 不切换
/// （主题包生态下预设可能被删，宁可不动也不落到错误形态）。
@MainActor
public final class DaylightSwitcher {
    private let settings: SettingsStore
    private let readPhase: @MainActor () -> DaylightPhase
    /// 去抖记忆：同相位重复求值不重放预设（避免外观无关的重绘与持久化写）
    private var lastApplied: DaylightPhase?
    private var observation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    /// readPhase 注入点：测试喂假相位序列；live 默认走系统外观
    public init(
        settings: SettingsStore,
        readPhase: @escaping @MainActor () -> DaylightPhase = DaylightPhase.currentSystemPhase
    ) {
        self.settings = settings
        self.readPhase = readPhase
    }

    /// 相位 → 预设键（纯函数）：亮=daylightTheme、暗=dayNightTheme
    public static func themeID(for phase: DaylightPhase, daylight: String, night: String) -> String {
        phase == .light ? daylight : night
    }

    /// 求值一次：start 时、外观变化时、三设置项变化时都会进来。
    /// 关闭态顺手清 lastApplied——关→再开从当前相位重新裁决，不带着旧记忆漏切
    public func evaluate() {
        guard settings.autoDaylightTheme else {
            lastApplied = nil
            return
        }
        let phase = readPhase()
        guard phase != lastApplied else { return }
        let id = Self.themeID(
            for: phase, daylight: settings.daylightTheme, night: settings.dayNightTheme
        )
        if let preset = ThemePresets.all[id] {
            _ = ThemeApplier.apply(preset, to: settings)
        }
        lastApplied = phase
    }

    /// live 接线：KVO 系统外观 + 订阅三设置项（removeDuplicates 防回环——
    /// ThemeApplier 写 store 也会触发本订阅，靠相位去抖拦住）
    public func start() {
        evaluate()
        observation = NSApplication.shared.observe(
            \.effectiveAppearance, options: [.initial, .new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        Publishers.Merge3(
            settings.$autoDaylightTheme.removeDuplicates(),
            settings.$daylightTheme.removeDuplicates().map { _ in false },
            settings.$dayNightTheme.removeDuplicates().map { _ in false }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.evaluate() }
        .store(in: &cancellables)
    }

    public func stop() {
        observation?.invalidate()
        observation = nil
        cancellables.removeAll()
        lastApplied = nil
    }
}
