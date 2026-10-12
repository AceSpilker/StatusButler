import Foundation

// MARK: - 每 App 音量·用户态半场（T-050 · A11 E20 PAV-01/PAV-03）
// 诚实边界：macOS 没有公开的"每 App 音量"API；增益真正施加在 DriverKit 虚拟声卡
// （T-050b，需向 Apple 申请 DriverKit audio entitlement 后接线）。本文件是驱动之外
// 的一切：通道/规则模型 + 规则引擎纯函数，零系统调用，可独立编译测试（PAV-05 驱动可摘除）。

/// 混音台里一个正在发声 App 的一行（PAV-01）。App 退出即由驱动侧事件收回。
/// gainPercent 构造即钳制 0-100：驱动侧只接受该区间，脏持久化数据不外溢到 HAL。
public struct PerAppChannel: Codable, Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var displayName: String
    /// 用户滑杆目标值（0-100，构造钳制）。
    public var gainPercent: Int
    public var isMuted: Bool
    /// 通道级硬上限（PAV-03"某 App 永不超过 X%"），nil = 该通道未单独设限。
    /// 与命中规则的 maxGain 取最严者，见 PerAppRuleEngine。
    public var ruleCap: Int?

    public var id: String { bundleID }

    public init(
        bundleID: String,
        displayName: String,
        gainPercent: Int,
        isMuted: Bool = false,
        ruleCap: Int? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.gainPercent = Self.clamp(gainPercent)
        self.isMuted = isMuted
        self.ruleCap = ruleCap.map(Self.clamp)
    }

    static func clamp(_ value: Int) -> Int { min(max(value, 0), 100) }
}

/// 一条混音规则（PAV-03）。match 为子串：对 bundleID 或显示名做不区分大小写的包含匹配，
/// 让"spotify"这类口语化输入也能命中。
public struct PerAppRule: Codable, Sendable, Equatable {
    public var match: String
    /// 命中 App 的增益硬上限（"永不超过 X%"，构造钳制 0-100）。
    public var maxGain: Int
    /// 按 App 记住音量（重启生效）：仅标记哪些 App 的滑杆值需要落盘，持久化由设置层负责。
    public var rememberPerApp: Bool
    /// 焦点 App 自动抬升（可选，默认关）：+20，仍受最严上限与 100 双重封顶。
    public var boostWhenFocused: Bool

    public init(
        match: String,
        maxGain: Int = 100,
        rememberPerApp: Bool = false,
        boostWhenFocused: Bool = false
    ) {
        self.match = match
        self.maxGain = PerAppChannel.clamp(maxGain)
        self.rememberPerApp = rememberPerApp
        self.boostWhenFocused = boostWhenFocused
    }
}

// MARK: - 规则引擎（纯函数）
/// 输入通道快照 + 规则集 +（可选）当前焦点 App → 输出目标增益表，驱动侧照表施加。
/// 冲突语义：多条规则命中同一 App 时取最严格上限——"永不超过"是用户明示的安全承诺，
/// 焦点抬升（+20）只允许在剩余余量内生效，绝不击穿上限。
public enum PerAppRuleEngine {
    /// 焦点抬升幅度（PAV-03 规格值）。
    public static let focusBoostPercent = 20

    public static func applyRules(
        channels: [PerAppChannel],
        rules: [PerAppRule],
        focusedBundleID: String? = nil
    ) -> [String: Int] {
        var gains: [String: Int] = [:]
        gains.reserveCapacity(channels.count)
        for channel in channels {
            gains[channel.bundleID] = effectiveGain(
                of: channel, rules: rules, focusedBundleID: focusedBundleID)
        }
        return gains
    }

    /// 单通道目标增益：静音 > 最严上限 > 焦点抬升，逐层收窄。
    public static func effectiveGain(
        of channel: PerAppChannel,
        rules: [PerAppRule],
        focusedBundleID: String? = nil
    ) -> Int {
        // 静音优先：静音时用户听到的就是 0，任何上限/抬升都不改写这一事实
        guard !channel.isMuted else { return 0 }
        let matched = rules.filter { matches($0, channel) }
        // 最严上限 = 通道自带 cap 与所有命中规则 maxGain 的最小值
        var cap = channel.ruleCap
        for rule in matched {
            cap = min(cap ?? rule.maxGain, rule.maxGain)
        }
        var gain = channel.gainPercent
        if let cap { gain = min(gain, cap) }
        if let focusedBundleID, focusedBundleID == channel.bundleID,
           matched.contains(where: \.boostWhenFocused) {
            // 抬升只在余量内生效：+20 后仍被"永不超过"上限与 100 双重钳制
            gain = min(gain + focusBoostPercent, 100)
            if let cap { gain = min(gain, cap) }
        }
        return gain
    }

    /// 规则是否命中通道：子串匹配 bundleID 或显示名（不区分大小写）。
    /// 空/纯空白串会 contains 一切，等于一条隐形全局规则——直接判不命中。
    public static func matches(_ rule: PerAppRule, _ channel: PerAppChannel) -> Bool {
        let needle = rule.match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return channel.bundleID.localizedCaseInsensitiveContains(needle)
            || channel.displayName.localizedCaseInsensitiveContains(needle)
    }

    /// 需要按 App 落盘音量的集合（PAV-03"按 App 记住音量"）：
    /// 只有命中 rememberPerApp 规则的 App 才进持久化，避免全量写盘。
    public static func rememberedBundleIDs(
        channels: [PerAppChannel],
        rules: [PerAppRule]
    ) -> Set<String> {
        let rememberRules = rules.filter(\.rememberPerApp)
        guard !rememberRules.isEmpty else { return [] }
        return Set(channels
            .filter { channel in rememberRules.contains { matches($0, channel) } }
            .map(\.bundleID))
    }
}
