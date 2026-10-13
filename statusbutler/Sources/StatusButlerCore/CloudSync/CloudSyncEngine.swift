import CloudKit
import Combine
import Foundation

// MARK: - E8 iCloud 设置同步（A9 · IC-01~04，A14-ε）
// 范围（IC-01）：设置 + 主题两块 JSON；E10 历史、隐私/网络/权限类配置一概不同步。
// 本文件不 import 设置/主题模块——快照的打包与应用走注入闭包（依赖单向铁律：
// CloudSync 是旁路消费者，不允许反向触碰 Store 层；闭包签名见 LocalSnapshotProvider）。

/// 云端同步记录。payload 用 JSON 装箱而非结构化字段：设置模型演进由本地编解码自洽
/// （未知键忽略向前兼容），云端 schema 不随 UI 改版迁移——两边解耦，改设置字段不动云记录。
public struct CloudSettingsRecord: Equatable, Sendable {
    public var settingsJSON: Data
    public var themeJSON: Data
    /// LWW 裁决依据（IC-03）：本设备最后修改时间（写入云端前由闭包侧盖时间戳）
    public var modified: Date
    /// 冲突提示用（IC-03："展示双方修改时间与设备名"）
    public var deviceName: String

    public init(settingsJSON: Data, themeJSON: Data, modified: Date, deviceName: String) {
        self.settingsJSON = settingsJSON
        self.themeJSON = themeJSON
        self.modified = modified
        self.deviceName = deviceName
    }
}

/// LWW 冲突裁决（IC-03）。时间戳严格较新者胜是默认（最后写入胜出）；
/// 完全相等（同刻双设备写入撞车）才交人工——携带双方数据，裁决前不写任何一侧。
public enum ConflictResolution: Equatable, Sendable {
    case localWins
    case remoteWins
    case manual(local: CloudSettingsRecord, remote: CloudSettingsRecord)
}

/// 手动"立即同步"结果（IC-02：手动为主，自动可选——本枚举就是手动按钮的完整返回面）。
public enum SyncOutcome: Equatable, Sendable {
    /// 本地较新（或云端无记录）：上行覆盖
    case pushed
    /// 远端较新：下行应用
    case pulled
    case conflict(ConflictResolution)
    /// 失败含"未开启"与 CloudKit 异常。IC-04：失败静默降级本地模式——
    /// 本地数据零损失、不弹窗、不重试风暴，原因透传设置页展示即可
    case failed(String)
}

// MARK: - 存储协议（监控器纪律：协议化 + 测试注入假实现）

public protocol CloudStoring: Sendable {
    func save(_ record: CloudSettingsRecord) async throws
    /// 云端无记录（首台设备首次同步）返回 nil
    func load() async throws -> CloudSettingsRecord?
}

// MARK: - CloudKit 实现（私有数据库，IC-02）
/// 单记录模型：recordName = "current"。设置快照语义上是"一个当前值"不是追加流水——
/// 天然没有列表合并问题，只剩 LWW 一题。用户自己的 iCloud 配额，无服务器运营。
public struct CloudKitStore: CloudStoring {
    /// 云端 record 类型名。与 CloudKit Console 里建的 schema 对齐，改名 = 换同步域
    public static let recordType = "SettingsSnapshot"
    public static let recordName = "current"
    /// 容器 id 必须与主 App entitlements 的 com.apple.developer.icloud-container-identifiers 一致
    /// （见集成注记：Support/Info.plist 之外还需签名的 entitlements 文件）
    public static let containerIdentifier = "iCloud.com.linzhongyang.statusbutler"

    private let container: CKContainer

    /// 组装入口（"容器不存在时初始化抛错降级"的落点，IC-04）：
    /// CKContainer(identifier:) 构造本身不触网、不校验 entitlement——容器/iCloud 账号
    /// 不可用的真相要到 accountStatus 才揭晓，所以"初始化抛错"放在这个 async 工厂。
    /// 集成方 `try await` 失败后改装配禁用态协调器（或本地降级件），是显式降级路径。
    public static func makeValidated() async throws -> CloudKitStore {
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()  // entitlement 缺失 → notEntitled 类错误在此现身
        guard status == .available else {
            throw CloudKitSetupError.accountUnavailable(
                "iCloud 账号不可用（CKAccountStatus raw \(status.rawValue)）")
        }
        return CloudKitStore(container: container)
    }

    private init(container: CKContainer) {
        self.container = container
    }

    public func save(_ record: CloudSettingsRecord) async throws {
        let ck = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: Self.recordName))
        ck["settingsJSON"] = record.settingsJSON as NSData
        ck["themeJSON"] = record.themeJSON as NSData
        ck["modified"] = record.modified as NSDate
        ck["deviceName"] = record.deviceName as NSString
        // changedKeys（不做乐观锁）：单记录模型 + 本同步已完成 LWW 裁决 → 无条件覆盖
        // 本次决定要写的键；serverRecordChanged 类竞态留给下一次手动同步再裁决
        _ = try await container.privateCloudDatabase.modifyRecords(
            saving: [ck], deleting: [], savePolicy: .changedKeys, atomically: true)
    }

    public func load() async throws -> CloudSettingsRecord? {
        do {
            let ck = try await container.privateCloudDatabase.record(
                for: CKRecord.ID(recordName: Self.recordName))
            return Self.decode(ck)
        } catch let error as CKError where error.code == .unknownItem {
            return nil  // 首台设备：云端还没有快照
        }
    }

    /// 字段残缺（对端 App 版本更旧/云端被手动改过）按"无记录"处理：
    /// 本地 LWW 上行覆盖顺手把它修好，比抛错中断同步更符合"同步是自愈操作"的定位
    private static func decode(_ ck: CKRecord) -> CloudSettingsRecord? {
        guard let settings = ck["settingsJSON"] as? Data,
              let theme = ck["themeJSON"] as? Data,
              let modified = ck["modified"] as? Date else { return nil }
        return CloudSettingsRecord(
            settingsJSON: settings,
            themeJSON: theme,
            modified: modified,
            deviceName: (ck["deviceName"] as? String) ?? "未知设备"
        )
    }
}

public enum CloudKitSetupError: Error, Equatable, Sendable {
    case accountUnavailable(String)
}

// MARK: - 快照桥（注入闭包）
/// 本地快照打包：集成方（主 App 组合根）读 SettingsStore/主题当前值 → 两块 JSON + 时间戳。
/// @MainActor：读的是 @MainActor 的设置仓库，闭包隔离域与协调器对齐，无需跨隔离搬运
public typealias LocalSnapshotProvider = @MainActor @Sendable () -> CloudSettingsRecord?
/// 远端快照应用：集成方把两块 JSON 解码后写回本地（含"采纳远端 modified 时间戳"——
/// 否则本机下一次快照的 modified 仍早于远端，每次同步都会重复 pull）
public typealias RemoteRecordApplier = @MainActor @Sendable (CloudSettingsRecord) -> Void

// MARK: - 协调器（状态机：默认关闭）
/// 手动同步协调器（IC-02/04）。开关默认关，且"关闭态零云调用"是可测试契约而非口头承诺：
/// isEnabled == false 时 syncNow/settleConflict 首行就返回，store 一个字节都不碰
/// （测试断言假 store 的调用计数为 0）。
@MainActor
public final class SyncCoordinator: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case syncing
    }

    public static let disabledReason = "iCloud 同步未开启（默认关闭，IC-04）"

    @Published public private(set) var phase: Phase = .idle

    /// 上一次 syncNow 撞出的待人工裁决冲突（IC-03：设置页直接消费；nil = 无待决）
    public private(set) var pendingConflict: (local: CloudSettingsRecord, remote: CloudSettingsRecord)?

    private let store: any CloudStoring
    private let localSnapshot: LocalSnapshotProvider
    private let applyRemote: RemoteRecordApplier
    private var isEnabled: Bool

    public init(
        store: any CloudStoring,
        localSnapshot: @escaping LocalSnapshotProvider,
        applyRemote: @escaping RemoteRecordApplier,
        isEnabled: Bool = false  // 默认关闭（IC-04）：开启是设置页的显式动作
    ) {
        self.store = store
        self.localSnapshot = localSnapshot
        self.applyRemote = applyRemote
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ on: Bool) {
        isEnabled = on
    }

    // MARK: - LWW 裁决（纯函数，可单测）

    /// nil remote（云端空）→ 直接上行；时间戳严格较新者胜；相等 → manual 携带双方。
    /// 只产出 pushed/pulled/conflict 三种（failed 属于 IO 层，不属裁决层）。
    public static func resolve(local: CloudSettingsRecord, remote: CloudSettingsRecord?) -> SyncOutcome {
        guard let remote else { return .pushed }
        if local.modified > remote.modified { return .pushed }
        if remote.modified > local.modified { return .pulled }
        return .conflict(.manual(local: local, remote: remote))
    }

    // MARK: - 手动同步

    public func syncNow() async -> SyncOutcome {
        guard isEnabled else { return .failed(Self.disabledReason) }  // 关闭态零云调用
        guard let local = localSnapshot() else {
            return .failed("本地快照不可用：设置打包闭包未就绪（组合根未接线）")
        }
        phase = .syncing
        defer { phase = .idle }
        do {
            let remote = try await store.load()
            switch Self.resolve(local: local, remote: remote) {
            case .pushed:
                try await store.save(local)
                return .pushed
            case .pulled:
                // resolve 的 .pulled 只在 remote 非 nil 时产出；解包失败属逻辑回归，
                // 诚实失败优于静默错同步
                guard let remote else { return .failed("LWW 裁决与云端记录不一致") }
                applyRemote(remote)
                return .pulled
            case .conflict(let resolution):
                // 只可能是 manual（严格不等已分流 pushed/pulled）；存入待决账，不写任何一侧
                if case .manual(let localRecord, let remoteRecord) = resolution {
                    pendingConflict = (localRecord, remoteRecord)
                }
                return .conflict(resolution)
            case .failed:
                return .failed("不可达：resolve 不产出 failed（穷举防御）")
            }
        } catch {
            // IC-04：网络/账号/配额类异常静默降级本地模式——数据不动、不弹窗不重试
            return .failed("CloudKit 操作失败：\(error)")
        }
    }

    // MARK: - 冲突人工裁决（IC-03："展示双方修改时间与设备名供选择"之后的出口）

    /// settleConflict(winner:)：localWins → 上行本地快照；remoteWins → 下行应用远端。
    /// 不回写云端：云端持有的就是胜出的那份，再存一次只会刷新 deviceName 挑起下一轮撞车。
    public func settleConflict(winner: ConflictResolution) async -> SyncOutcome {
        guard isEnabled else { return .failed(Self.disabledReason) }
        guard let pending = pendingConflict else {
            return .failed("当前无待裁决冲突")
        }
        switch winner {
        case .localWins:
            do {
                try await store.save(pending.local)
                pendingConflict = nil
                return .pushed
            } catch {
                return .failed("CloudKit 操作失败：\(error)")
            }
        case .remoteWins:
            applyRemote(pending.remote)
            pendingConflict = nil
            return .pulled
        case .manual:
            return .failed("人工裁决只接受 localWins 或 remoteWins")
        }
    }
}
