import SwiftUI

// T-031：设置中心公共骨架——分区枚举 + 统一行组件 + 槽位选项数据源。
// 行组件对标 macOS 偏好设置的经典"标题+副标题+右侧控件"版式，
// 每个分区不再各自摆 HStack，保证四个 pane 视觉与对齐一致。

// MARK: - 分区枚举（侧栏数据源；CaseIterable 顺序即展示顺序）

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case panel
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "状态图标外观"
        case .panel: "状态面板"
        case .about: "关于"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .panel: "rectangle.stack"
        case .about: "info.circle"
        }
    }
}

// MARK: - 统一行组件

/// 通用偏好行：左侧标题（可选副标题），右侧控件。副标题写"为什么/边界"，不重复标题
public struct PreferenceRow<Control: View>: View {
    private let title: String
    private let subtitle: String?
    private let control: Control

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

/// 复选框行（macOS 偏好设置最常见形态）：标题在控件右侧，整行即热区
public struct PreferenceCheckboxRow: View {
    private let title: String
    private let subtitle: String?
    private let isOn: Binding<Bool>

    public init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - 槽位选项（Appearance 分区 Picker 的数据源；独立成纯数据便于测试钉死）

public struct SettingsSlotOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// true = 注册表占位（PendingSlot），数据源未接入，UI 侧灰显标注"待数据源"
    public let isPending: Bool
}

public enum SettingsSlotOptions {
    /// 已实现源在前、占位源在后，各自按 id 排序——展示顺序确定， Picker 与测试共用同一份
    public static let all: [SettingsSlotOption] = {
        let entries = SlotRegistry.builtin
        let implemented = entries.keys.filter { !(entries[$0] is PendingSlot) }.sorted()
        let pending = entries.keys.filter { entries[$0] is PendingSlot }.sorted()
        let titleByID: [String: String] = [
            "volume": "音量点",
            "clock": "时钟",
            "batteryPercent": "电池百分比",
            "diskFree": "磁盘剩余",
            "netSpeed": "网速",
            "cpuUsage": "CPU 占用",
            "memoryPressure": "内存压力",
            "temperature": "温度",
            "weather": "天气",
            "calendarCountdown": "日历倒数",
        ]
        return (implemented + pending).map { id in
            SettingsSlotOption(
                id: id,
                title: titleByID[id] ?? id,
                isPending: entries[id] is PendingSlot
            )
        }
    }()

    public static func option(id: String) -> SettingsSlotOption? {
        all.first { $0.id == id }
    }
}
