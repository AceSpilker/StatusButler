import SwiftUI

// T-032: 取词 helper——SwiftUI 与 AppKit（非 SwiftUI）两个入口共用同一张表。
// 键收敛在 LocalizationKey：后续迁 .lproj 时只改 Localization.string(_:) 的实现，本文件不动

extension Text {
    /// SwiftUI 简写：Text.localized(.panelBattery, in: localization)
    /// 用 Text(String) 而非 Text(LocalizedStringKey)，避免 AppKit 侧二次查表
    public static func localized(_ key: LocalizationKey, in localization: Localization) -> Text {
        Text(localization.string(key))
    }
}

extension String {
    /// 非 SwiftUI 场景（NSMenu / NSMenuItem / 工具提示）的 String 直取：
    /// NSMenuItem(title: .localized(.menuQuit, in: loc), action: …, keyEquivalent: "")
    public static func localized(_ key: LocalizationKey, in localization: Localization) -> String {
        localization.string(key)
    }
}
