import Foundation

// T-033 / E7·TH-03：内置 6 套预设。差异化必须落在真实字段上——
// 预设是主题格式的"活文档"，每套定位可被测试钉死，防止将来改预设时互相趋同。
public enum ThemePresets {
    public static let all: [String: ButlerTheme] = [
        // 极简：小图标、无环、少分区、不显示百分比，信息密度最低
        "minimal": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 16,
                symbolScale: 0.9,
                ringStyle: .plain,
                batteryThreshold: 10,
                showsBatteryPercentage: false
            ),
            sections: ["slots", "appearance"],
            footerSlotID: "clock"
        ),
        // 高对比：低阈值早警示 + 自定义强调色，弱视力场景可用性优先
        "highContrast": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 18,
                ringStyle: .solid,
                batteryThreshold: 30,
                accentHex: "0A0A0A",
                warningHex: "FF0000",
                showsBatteryPercentage: true
            ),
            sections: ["appearance", "battery", "slots"],
            footerSlotID: "batteryPercent"
        ),
        // 彩色：分段环 + 状态分色（警示/充电各自着色），视觉信息最丰富
        "colorful": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 18,
                symbolScale: 1.1,
                ringStyle: .segmented,
                batteryThreshold: 20,
                accentHex: "5E5CE6",
                warningHex: "FF9F0A",
                chargingHex: "30D158"
            ),
            sections: ["appearance", "battery", "slots"],
            footerSlotID: "netSpeed"
        ),
        // 暗夜：夜间减光色调，细环降噪
        "darkNight": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 18,
                ringStyle: .thin,
                batteryThreshold: 15,
                accentHex: "64D2FF",
                warningHex: "FF453A"
            ),
            sections: ["appearance", "slots", "battery"],
            footerSlotID: "clock"
        ),
        // 经典 Mac：槽形环 + 近黑强调色 + 音量底部槽，System 7 气质
        "classicMac": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 18,
                ringStyle: .bezel,
                batteryThreshold: 20,
                accentHex: "333333"
            ),
            sections: ["appearance", "slots", "battery", "about"],
            footerSlotID: "volume"
        ),
        // 大字版：图标顶格 + 符号放大 + 常显百分比，可读性优先于密度
        "largeText": ButlerTheme(
            appearance: ThemeAppearance(
                iconSize: 24,
                symbolScale: 1.4,
                ringStyle: .solid,
                batteryThreshold: 20,
                showsBatteryPercentage: true
            ),
            sections: ["appearance", "battery", "slots"],
            footerSlotID: "batteryPercent"
        ),
    ]
}
