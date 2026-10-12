import Foundation
import Network
import os

// T-024: NWPathMonitor 包装 → ConnectionDetails。
// S5·OG-FR-141：VPN 状态行"只显示，不进图标渲染键"，故本模型是面板旁路数据，
// 与 NetworkLink（快照渲染键）并列，由主线决定是否桥接进 StatusSnapshot
public protocol ConnectionMonitoring: Sendable {
    func read() async -> ConnectionDetails
}

/// NWInterface.InterfaceType 的自研值快照：NWPath / NWInterface / InterfaceType
/// 均非 Sendable，跨线程只传本枚举（折叠动作在 monitor 专属队列内完成）
public enum ConnectionInterfaceType: String, Hashable, Sendable, CaseIterable {
    case wifi
    case wiredEthernet
    case cellular
    case loopback
    case other

    public init(_ type: NWInterface.InterfaceType) {
        switch type {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .wiredEthernet
        case .cellular: self = .cellular
        case .loopback: self = .loopback
        default: self = .other
        }
    }
}

public struct ConnectionDetails: Equatable, Sendable {
    /// path.status == .satisfied（.requiresConnection 视为未满足）
    public var isSatisfied: Bool
    /// 计费链路（蜂窝 / 个人热点等）
    public var isExpensive: Bool
    /// 低数据模式（受限网络）
    public var isConstrained: Bool
    /// 检测到 utun 隧道接口；判定局限见 details(isSatisfied:...) 注释
    public var isVPN: Bool
    public var interfaceTypes: Set<ConnectionInterfaceType>

    public init(
        isSatisfied: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isVPN: Bool,
        interfaceTypes: Set<ConnectionInterfaceType>
    ) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isVPN = isVPN
        self.interfaceTypes = interfaceTypes
    }

    /// monitor 首个 path 回调到达前的初值
    public static let offline = ConnectionDetails(
        isSatisfied: false, isExpensive: false, isConstrained: false,
        isVPN: false, interfaceTypes: []
    )
}

/// @unchecked Sendable 论证：NWPathMonitor 配置仅在 init 内设置并 start，之后只读 + cancel；
/// handler 在专属串行队列上把非 Sendable 的 NWPath 折叠成 ConnectionDetails 后才入锁，
/// 锁内为值类型，读侧无可变状态逃逸
public final class NetworkConnectionMonitor: ConnectionMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = OSAllocatedUnfairLock(initialState: ConnectionDetails.offline)

    public init() {
        // 本 SDK 的 Network 只暴露 pathUpdateHandler（@preconcurrency）；
        // 更新的 pathUpdateEstimatedHandler 不在 CLT swiftinterface 里
        monitor.pathUpdateHandler = { [lock] path in
            let interfaces = path.availableInterfaces
            let details = Self.details(
                isSatisfied: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                interfaceNames: interfaces.map(\.name),
                types: interfaces.map { ConnectionInterfaceType($0.type) }
            )
            lock.withLock { $0 = details }
        }
        monitor.start(queue: DispatchQueue(label: "statusbutler.network-connection-monitor"))
    }

    public func read() async -> ConnectionDetails {
        lock.withLock { $0 }
    }

    deinit {
        monitor.cancel()
    }

    /// 纯映射：path 原始信号 → ConnectionDetails（单测注入假数据，不碰 Network 框架）。
    /// interfaceNames 与 types 必须是 path.availableInterfaces 的平行数组。
    /// isVPN 判定局限（utun 前缀 + type == .other）：
    /// - utun 也被 iCloud 私人中继、Handoff 等系统隧道复用，可能误报；
    /// - 非 utun 命名的第三方 VPN（TAP / 自定义 utun 别名）会漏报。
    /// 仅作面板提示，不做安全或路由判定
    public static func details(
        isSatisfied: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        interfaceNames: [String],
        types: [ConnectionInterfaceType]
    ) -> ConnectionDetails {
        let isVPN = zip(interfaceNames, types).contains {
            $0.1 == .other && $0.0.hasPrefix("utun")
        }
        return ConnectionDetails(
            isSatisfied: isSatisfied,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            isVPN: isVPN,
            interfaceTypes: Set(types)
        )
    }
}
