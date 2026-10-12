import Foundation

// MARK: - 分区标识（T-030）

/// 弹层面板分区（A2·S3 分区化内容）。rawValue 即持久化键——新增分区只能追加，
/// 不得重排/改名旧值（旧版本写入的布局 JSON 依赖它前向兼容解码）
public enum PanelSectionID: String, CaseIterable, Codable, Sendable {
    case battery
    case network
    case volume
    case bluetooth
    case thermal
    case performance

    /// 分区中文标题（纯函数：无状态无副作用，展示层专用）
    public var displayName: String {
        switch self {
        case .battery: return "电池"
        case .network: return "网络"
        case .volume: return "音量"
        case .bluetooth: return "蓝牙"
        case .thermal: return "温度"
        case .performance: return "性能"
        }
    }

    /// 分区 SF Symbol 名（纯函数；只选 macOS 13 系统符号集内的名字，避免按系统版本分支）
    public var symbolName: String {
        switch self {
        case .battery: return "battery.100"
        case .network: return "wifi"
        case .volume: return "speaker.wave.2"
        case .bluetooth: return "bluetooth"
        case .thermal: return "thermometer.medium"
        case .performance: return "gauge"
        }
    }
}

// MARK: - 分区布局（显隐 + 排序，A2·S3）

/// visibleSections 是"要显示的集合"，order 是"全量分区的排列"——显隐与排序解耦：
/// 设置页拖动只改 order，勾选只改 visibleSections；order 永远是全量排列而非子集，
/// 这样未来新增分区时旧布局补一个 id 即可，不必迁移显隐语义
public struct PanelLayout: Codable, Sendable, Equatable {
    public var visibleSections: [PanelSectionID]
    public var order: [PanelSectionID]

    public init(visibleSections: [PanelSectionID], order: [PanelSectionID]) {
        self.visibleSections = visibleSections
        self.order = order
    }

    /// 默认布局：全分区可见，按声明序排列
    public static let `default` = PanelLayout(
        visibleSections: PanelSectionID.allCases,
        order: PanelSectionID.allCases
    )

    /// 布局合法性：order 无重复且覆盖全部分区（排序是全量排列）；
    /// visibleSections 无重复且是 order 的子集。空 visible（用户全部隐藏）合法
    public var isValid: Bool {
        let orderSet = Set(order)
        guard orderSet.count == order.count,
              orderSet == Set(PanelSectionID.allCases)
        else { return false }
        let visibleSet = Set(visibleSections)
        guard visibleSet.count == visibleSections.count else { return false }
        return visibleSet.isSubset(of: orderSet)
    }

    /// 修复式净化（持久化读回防御）：order 去重保序、缺失分区按声明序追加在末尾；
    /// visibleSections 去重并剔除不在 order 中的项——任何损坏输入都收敛回合法布局，
    /// 调用方不必因旧版本数据缺新分区 id 而整体丢弃用户设置
    public func sanitized() -> PanelLayout {
        var seen: Set<PanelSectionID> = []
        var repairedOrder: [PanelSectionID] = []
        for id in order where !seen.contains(id) {
            seen.insert(id)
            repairedOrder.append(id)
        }
        for id in PanelSectionID.allCases where !seen.contains(id) {
            seen.insert(id)
            repairedOrder.append(id)
        }
        let orderSet = Set(repairedOrder)
        var repairedVisible: [PanelSectionID] = []
        var visibleSeen: Set<PanelSectionID> = []
        for id in visibleSections
        where orderSet.contains(id) && !visibleSeen.contains(id) {
            visibleSeen.insert(id)
            repairedVisible.append(id)
        }
        return PanelLayout(visibleSections: repairedVisible, order: repairedOrder)
    }
}
