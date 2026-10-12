import Foundation

// MARK: - 驱动安装状态机 + 直通保护（T-050 · A11 E20 PAV-02/PAV-04/PAV-05）
// 零系统调用：安装向导只是状态与文案的编排，真正的系统扩展请求（OSSystemExtensionRequest）
// 与驱动激活检测由 T-050b 接线层完成，事件喂进本纯函数。failed 携带的原因文案由
// 向导层负责映射本地化，本层只保证语义稳定。

/// 安装向导状态。unsupportedOS 为终态：系统版本低于 DriverKit 音频要求，升级前无任何转移。
public enum DriverInstallState: Equatable, Sendable {
    case notInstalled
    case installing
    case needsUserApproval
    case installed
    case failed(String)
    case unsupportedOS

    /// PAV-05：不装驱动时功能整体隐藏——UI 用它决定混音台入口是否出现。
    public var isDriverReady: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// 状态机事件（由安装进程回调 / 系统扩展同意流程 / 驱动检测时钟产生）。
public enum DriverInstallEvent: Equatable, Sendable {
    case userRequestedInstall
    /// 系统弹出"需要在系统设置中批准"（macOS 系统扩展同意流程）。
    case approvalRequired
    case approvalGranted
    case approvalDenied
    /// 看门狗超时：等激活（installing）或等用户去系统设置批准（needsUserApproval）都算。
    case installTimedOut
    case installFailed(String)
    /// 虚拟设备上线（含启动即发现上次遗留安装的场景）。
    case driverDetected
    /// 驱动失联或被用户在系统设置里手动停用。
    case driverLost
    case uninstallRequested
    case osUnsupportedDetected
}

public enum DriverLifecycle {
    /// 纯转移函数：返回 nil = 非法转移（事件与当前状态时序不匹配），调用方保持原状态。
    /// 显式拒绝而非静默吞掉，是为了把"批准前驱动就激活""已安装又请求安装"这类
    /// 异常时序钉死在测试里——它们往往意味着接线层出了 bug。
    public static func next(
        state: DriverInstallState,
        event: DriverInstallEvent
    ) -> DriverInstallState? {
        switch (state, event) {
        // 未安装：发起安装 / 启动即发现遗留驱动（跳过向导直达已装）/ 系统版本不够
        case (.notInstalled, .userRequestedInstall): return .installing
        case (.notInstalled, .driverDetected): return .installed
        case (.notInstalled, .osUnsupportedDetected): return .unsupportedOS
        // 安装中：等待同意流程、驱动激活，或失败/超时/用户取消
        case (.installing, .approvalRequired): return .needsUserApproval
        case (.installing, .driverDetected): return .installed
        case (.installing, .installTimedOut): return .failed("安装超时：驱动未在预期时间内激活")
        case (.installing, .installFailed(let reason)): return .failed(reason)
        case (.installing, .uninstallRequested): return .notInstalled
        // 待批准：批准后回到安装中等待激活（批准≠设备已上线）；拒绝/超时/放弃各有归宿
        case (.needsUserApproval, .approvalGranted): return .installing
        case (.needsUserApproval, .approvalDenied): return .failed("用户在系统设置中拒绝了系统扩展")
        case (.needsUserApproval, .installTimedOut): return .failed("等待系统设置批准超时")
        case (.needsUserApproval, .uninstallRequested): return .notInstalled
        // 已安装：只剩离开——一键卸载，或驱动失联（含用户绕过 App 在系统设置移除）
        case (.installed, .uninstallRequested): return .notInstalled
        case (.installed, .driverLost): return .notInstalled
        // 失败：允许原地重试，也允许清理回未安装
        case (.failed, .userRequestedInstall): return .installing
        case (.failed, .uninstallRequested): return .notInstalled
        // unsupportedOS 终态 + 其余全部组合：nil 拒绝
        default: return nil
        }
    }
}

// MARK: - 卸载语义（PAV-02"卸载后完全恢复原状"）
// 一键卸载 = 请求系统扩展停用并移除 + 默认输出设备自动指回真实声卡 + 删除本功能的
// 全部持久化（记住的每 App 音量/规则随设置项一起清）。DriverKit 系统扩展是用户态进程，
// 随停用即被系统收回，没有 kext 残骸；音频栈回到"从未装过"的状态。
// 状态机上对应 installed --uninstallRequested--> notInstalled，
// 驱动被绕过移除的场景由 installed --driverLost--> notInstalled 兜底。

// MARK: - 直通保护（PAV-04）
/// 专业音频 App（CoreAudio 独占/低延迟虚拟声卡类）与我们注入的虚拟输出设备互斥：
/// 检测到即整体直通（目标增益表全量视为 100、驱动旁路）并提示用户——
/// 宁可损失本功能也不干扰创作链路。清单用 bundleID 全等匹配：子串误报会让普通用户
/// 功能失效，漏报的版本后缀变体由 T-050b 驱动侧的进程枚举兜底。
public enum PassthroughGuard {
    /// 专业音频 App 清单（≥6 是 E20 规格下限；误加普通 App 比漏报更伤，新增需谨慎）。
    public static let professionalAudioBundleIDs: Set<String> = [
        "com.apple.logic10",               // Logic Pro
        "com.apple.mainstage3",            // MainStage
        "com.avid.ProTools",               // Pro Tools
        "com.ableton.live",                // Ableton Live
        "com.cockos.reaper",               // Reaper
        "com.steinberg.cubase",            // Cubase
        "com.steinberg.nuendo",            // Nuendo
        "com.audinate.dvs",                // Dante Virtual Soundcard
        "com.native-instruments.Traktor",  // Traktor Pro
        "com.bitwig.bitwigstudio",         // Bitwig Studio
    ]

    /// 返回正在运行的专业音频 App（用于提示文案"因 X 运行中已切换直通"）。
    public static func detectPassthroughConflict(runningBundleIDs: Set<String>) -> Set<String> {
        runningBundleIDs.intersection(professionalAudioBundleIDs)
    }

    /// 是否应进入直通模式（检测到任一专业音频 App 即 true）。
    public static func shouldEnterPassthrough(runningBundleIDs: Set<String>) -> Bool {
        !detectPassthroughConflict(runningBundleIDs: runningBundleIDs).isEmpty
    }
}
