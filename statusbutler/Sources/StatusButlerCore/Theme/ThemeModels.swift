import Foundation

// T-033 / E7·TH-01：.butler-theme 的数据形态。
// 只覆盖外观类配置；nil = "主题不覆盖此项"（SettingsStore 消费时跳过），
// 这是导入容错与"本机不支持字段提示跳过"（TH-05）的基础。

/// 状态环绘制形态：主题文件只存语义名，渲染层按此分派具体画法
public enum RingStyle: String, Codable, Sendable, CaseIterable {
    case plain      // 无环
    case thin
    case solid
    case segmented  // 分级点
    case bezel      // 经典 Mac 内嵌槽形
}

/// 外观覆盖项：全部可空，预设/导入文件只写自己关心的键
public struct ThemeAppearance: Codable, Sendable, Equatable {
    public var iconSize: Double?
    public var symbolScale: Double?
    public var ringStyle: RingStyle?
    public var batteryThreshold: Int?
    public var accentHex: String?
    public var warningHex: String?
    public var chargingHex: String?
    public var showsBatteryPercentage: Bool?

    public init(
        iconSize: Double? = nil,
        symbolScale: Double? = nil,
        ringStyle: RingStyle? = nil,
        batteryThreshold: Int? = nil,
        accentHex: String? = nil,
        warningHex: String? = nil,
        chargingHex: String? = nil,
        showsBatteryPercentage: Bool? = nil
    ) {
        self.iconSize = iconSize
        self.symbolScale = symbolScale
        self.ringStyle = ringStyle
        self.batteryThreshold = batteryThreshold
        self.accentHex = accentHex
        self.warningHex = warningHex
        self.chargingHex = chargingHex
        self.showsBatteryPercentage = showsBatteryPercentage
    }
}

/// 主题：sections 为分区排序 id 列表（id 由设置面板层定义，本层不解释内容，只保序）
public struct ButlerTheme: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var appearance: ThemeAppearance?
    public var sections: [String]?
    public var footerSlotID: String?

    public init(
        schemaVersion: Int = ButlerTheme.currentSchemaVersion,
        appearance: ThemeAppearance? = nil,
        sections: [String]? = nil,
        footerSlotID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.sections = sections
        self.footerSlotID = footerSlotID
    }

    /// hex → RGBA（0...1）。纯函数、容错：接受可选 "#" 前缀、RGB(6位)/RGBA(8位，CSS 字节序)、
    /// 大小写与首尾空白；其余（长度错、非十六进制字符）一律返回 nil 交由调用方决定回退色。
    /// 不依赖 AppKit 是刻意的：本文件属逻辑层，颜色空间的桥接归渲染层。
    public static func color(fromHex hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8 else { return nil }
        guard let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (r, g, b, a)
    }
}
