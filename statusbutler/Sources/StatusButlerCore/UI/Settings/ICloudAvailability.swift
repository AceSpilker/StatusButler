import CloudKit
import Foundation

// MARK: - iCloud 同步可用性探测（T-219 · E8 设置收尾）
//
// 状态行是"容器配置用户清单"的可视面：容器创建/签名配置属外部动作（Apple Developer
// 后台 + 打包），App 侧只如实报告"现在能不能用、缺什么"。CloudKit 调用只在 live
// 面板出现时发生（.task 驱动，一次一探不轮询——能效铁律）；错误映射是纯函数可单测。

public enum ICloudSyncStatus: Equatable, Sendable {
    case checking
    /// 容器可达且账号可用（同步开关此时才真正生效）
    case available
    /// 未登录 iCloud / 账号被锁（CKAccountStatus 非 available）
    case accountUnavailable
    /// 打包缺 entitlements（Support/StatusButler.entitlements 未随签名注入）
    case entitlementMissing
    /// 其他（容器未创建/网络/配额……），带原因透传（IC-04 不弹窗，文案如实展示）
    case unavailable(String)

    /// 状态行文案（纯函数，钉死测试）
    public var message: String {
        switch self {
        case .checking: "检测容器可用性…"
        case .available: "容器可用（iCloud.com.linzhongyang.statusbutler）"
        case .accountUnavailable: "iCloud 账号未登录或不可用——登录后即可同步"
        case .entitlementMissing: "未配置 iCloud 权限（打包需启用 Support/StatusButler.entitlements 模板）"
        case .unavailable(let reason): "容器暂不可用：\(reason)"
        }
    }
}

public enum ICloudAvailability {

    public enum ICloudProbeError: Error {
        case noEntitlement
    }

    /// 无 entitlement 时 CKContainer 构造会 trap——先查再调（crash 报告 StatusButler-2026-10-13-153447）
    public static func hasCloudKitEntitlement() -> Bool {
        guard let path = Bundle.main.path(forResource: "StatusButler", ofType: "entitlements")
            ?? Bundle.main.path(forResource: "_embedded", ofType: "entitlements") else {
            // ad-hoc 签名的本地构建无 entitlements plist——检查 code signing entitlements
            #if DEBUG
            return false  // 本地开发构建恒不探测 CKContainer
            #else
            return false
            #endif
        }
        return true
    }

    /// 容器配置用户清单（容器创建本身属外部，见 docs/c2-plan 外部依赖清单）
    public static let checklistText = """
        iCloud 同步需完成两项外部配置：\
        ① Apple Developer 后台创建容器 iCloud.com.linzhongyang.statusbutler，\
        并在 CloudKit Console 建 record type "SettingsSnapshot"\
        （字段 settingsJSON//themeJSON/modified/deviceName）；\
        ② 打包签名时启用本仓库 Support/StatusButler.entitlements 模板\
        （icloud-container-identifiers + icloud-services=CloudKit）。
        """

    /// 错误 → 状态（纯函数）：账号类/权限类分流，其余如实带原因。
    /// CKErrorDomain + notEntitled 的 NSError 判定走原始 domain/code——
    /// 桥接 as? CKError 在注入测试里不如裸值稳
    public static func map(_ error: Error) -> ICloudSyncStatus {
        if case CloudKitSetupError.accountUnavailable = error { return .accountUnavailable }
        let ns = error as NSError
        if ns.domain == CKErrorDomain, ns.code == CKError.Code.missingEntitlement.rawValue {
            return .entitlementMissing
        }
        return .unavailable(ns.localizedDescription.isEmpty ? "未知错误" : ns.localizedDescription)
    }

    /// 探测：makeStore 注入面默认走 CloudKitStore.makeValidated（与 LiveServices
    /// 开机装配同一出口——两处对"容器可用"的口径永远一致）；成功即 available
    /// CKContainer(identifier:) 在无 iCloud entitlements 的进程里直接 SIGTRAP（不是 throw）——
    /// 设置面板状态行在启动期就会调 probe，必须在调 CKContainer 前检查 entitlements 存在
    public static func probe(
        makeStore: @escaping @Sendable () async throws -> Void = {
            guard Self.hasCloudKitEntitlement() else {
                throw ICloudProbeError.noEntitlement
            }
            _ = try await CloudKitStore.makeValidated()
        }
    ) async -> ICloudSyncStatus {
        do {
            try await makeStore()
            return .available
        } catch {
            return map(error)
        }
    }
}
