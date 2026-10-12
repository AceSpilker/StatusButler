import Foundation

// T-031 / E7·TH-05：主题 → SettingsStore 的落地桥。
// 唯一职责：把 ButlerTheme 里"本机支持"的字段写进 store（@Published，改完即生效），
// 不支持的字段逐项说明后跳过——导入容错的用户反馈面，而不是静默吞掉。

@MainActor
public enum ThemeApplier {
    /// 应用主题到 store，返回"跳过项说明"（TH-05：本机不支持字段要有可读提示）。
    /// 说明顺序与字段检查顺序一致，保证数组内容可被测试钉死。
    public static func apply(_ theme: ButlerTheme, to store: SettingsStore) -> [String] {
        var skipped: [String] = []

        if let appearance = theme.appearance {
            if let iconSize = appearance.iconSize {
                // store 持久化侧不二次钳制（didSet 直写），越界值必须在这里拦，否则重启前图标会撑破菜单栏
                store.menuBarIconSize = min(max(iconSize, SettingsStore.iconSizeRange.lowerBound),
                                             SettingsStore.iconSizeRange.upperBound)
            }
            if let showsPercentage = appearance.showsBatteryPercentage {
                store.showsBatteryPercentage = showsPercentage
            }
            // 以下外观键在 v1 SettingsStore 尚无落点（随 S9 各分区任务接入），
            // 主题带值时必须显式提示"暂未支持"，避免用户以为已生效
            if appearance.symbolScale != nil { skipped.append("符号缩放（symbolScale）暂未支持") }
            if appearance.ringStyle != nil { skipped.append("环形样式（ringStyle）暂未支持") }
            if appearance.batteryThreshold != nil { skipped.append("低电阈值（batteryThreshold）暂未支持") }
            if appearance.accentHex != nil { skipped.append("强调色（accentHex）暂未支持") }
            if appearance.warningHex != nil { skipped.append("警示色（warningHex）暂未支持") }
            if appearance.chargingHex != nil { skipped.append("充电色（chargingHex）暂未支持") }
        }

        if theme.sections != nil {
            // PanelLayout 类型在 agent/popover 分支，未合入前不建第二份分区状态源（架构铁律：单一状态源）
            skipped.append("分区排序（sections）待状态面板布局合入")
        }

        if let slotID = theme.footerSlotID {
            if SlotRegistry.builtin[slotID] != nil {
                // PendingSlot 也放行：注册表占位本身就是"选了等数据源"的合法状态
                store.footerSlotID = slotID
            } else {
                skipped.append("底部槽位「\(slotID)」未注册，已跳过")
            }
        }
        return skipped
    }

    /// 从 store 导出当前配置为主题（导出用）：只装填本机支持的字段，
    /// sections 恒为 nil——面板分区排序 UI 尚不存在，导出不编造数据。
    public static func snapshot(from store: SettingsStore) -> ButlerTheme {
        ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: store.menuBarIconSize,
                showsBatteryPercentage: store.showsBatteryPercentage
            ),
            sections: nil,
            footerSlotID: store.footerSlotID
        )
    }
}
