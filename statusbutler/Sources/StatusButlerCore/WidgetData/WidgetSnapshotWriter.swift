import Foundation

// T-054a 写入半场（A6·4）：原子写快照文件 + Darwin 通知唤醒 + 写入节流决策。
// 目录注入化（测试传临时目录），通知封装成协议（测试注入假实现）——纯逻辑可测的边界铁律。

/// Darwin 通知的可注入抽象：主 App 侧只管"发"，扩展侧怎么收是 WidgetKit target 的集成事
public protocol NotifierPostable: Sendable {
    func post(_ name: String)
}

/// Darwin 通知实现。原理：CFNotificationCenterGetDarwinNotifyCenter 挂在系统级
/// com.apple.system.notification 命名空间上，post 只广播一个名字（无 payload、不传数据），
/// 内核把信号投递到所有监听该名字的进程 Mach 端口——这是主 App 与 WidgetKit 扩展两个进程间
/// 最廉价的"数据有更新"信号：扩展侧用 CFNotificationCenterAddObserver 监听同名通知，
/// 收到即读快照文件刷新时间线，不必干等系统按预算调度 TimelineProvider。
/// 与 WidgetCenter.reloadTimelines 双轨互补（前者即时、后者受刷新预算约束）。
public struct DarwinNotifier: NotifierPostable {
    public init() {}

    public func post(_ name: String) {
        // deliverImmediately 必须 true：Darwin 域不支持挂起/合并投递
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// 快照写入器：Monitoring→Store 之后挂一个轻量订阅者，每次采样后调用（A6·5）。
/// 写路径全程原子——扩展进程在任何时刻读到的都是完整旧文件或完整新文件，绝不会读到半截 JSON。
public struct WidgetSnapshotWriter: Sendable {
    /// Darwin 通知名（A6·4 图）：扩展侧监听同名通知即知快照已更新
    public static let notificationName = "com.linzhongyang.statusbutler.snapshot"
    public static let fileName = "widget-snapshot.json"

    public let directory: URL
    private let notifier: any NotifierPostable

    public var fileURL: URL { directory.appending(path: Self.fileName) }

    public init(
        directory: URL = WidgetSnapshotWriter.defaultDirectory(),
        notifier: (any NotifierPostable)? = nil
    ) {
        self.directory = directory
        self.notifier = notifier ?? DarwinNotifier()
    }

    /// 默认落点：应用支持目录下 StatusButler/WidgetData/。
    /// 非沙盒架构红利（A6·4）：主 App 与扩展同用户，直接共享这份文件即可，无需 App Group 容器；
    /// WidgetData/ 子目录同时容纳未来的交互命令文件（A6·3），与快照各占一个固定文件名。
    public static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "StatusButler/WidgetData")
    }

    // MARK: - 写入

    /// 原子写（临时文件 + rename）并发出 Darwin 通知。
    /// 抛错（磁盘满/目录不可建）由调用方决定静默降级——组件是旁路展示，不该拖垮主 App。
    public func write(_ snapshot: WidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // 临时文件必须与目标同目录：rename 只在同文件系统内是原子操作，跨卷会退化为拷贝露出半成品；
        // UUID 后缀防并发写时互相踩临时文件
        let tempURL = directory.appending(path: ".\(Self.fileName).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempURL) }  // rename 成功后 temp 已不存在；此行只兜底清理失败残留

        try data.write(to: tempURL)
        if fm.fileExists(atPath: fileURL.path()) {
            // 已有旧文件走 replaceItemAt（底层原子换名）而非先删后写——删与写之间的空窗读者会读到"文件缺失"
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: fileURL)
        }
        notifier.post(Self.notificationName)
    }

    // MARK: - 读取

    /// 容错读：文件缺失/坏 JSON/形态不识别一律返回 nil，调用方（扩展 TimelineProvider）沿用上一次缓存（A6·4）。
    /// NSFileCoordinator 协调读（A6·4 文件一致性）：为将来读写方挂进协调器体系预留，rename 原子性本身已保证不读到半截。
    public func read() -> WidgetSnapshot? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: fileURL,
            error: &coordinationError
        ) { url in
            data = try? Data(contentsOf: url)
        }
        guard coordinationError == nil, let data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    // MARK: - 节流决策（A6·4 三元组）

    /// 是否值得写文件/刷时间线：温度变化 ≥2°C、或转速变化 ≥300 RPM、或距上次 ≥30 秒，
    /// 三者满足其一才发——刷新预算是系统给的稀缺品，不能被秒级采样烧光（A6·1）。
    /// 纯函数：采样侧每次调用，文件写入与 WidgetCenter.reloadTimelines 共用同一判定。
    public static func shouldEmit(
        previous: WidgetSnapshot?,
        next: WidgetSnapshot,
        lastEmitAt: Date?,
        now: Date,
        minInterval: TimeInterval = 30,
        tempDelta: Double = 2,
        rpmDelta: Int = 300
    ) -> Bool {
        // 首写必发：小组件从"无数据"到"有数据"永远值得一次刷新
        guard let previous else { return true }
        if let lastEmitAt {
            // "距上次 ≥ minInterval"——即使数值纹丝不动也要发，否则组件永远显示旧时刻的数
            if now.timeIntervalSince(lastEmitAt) >= minInterval { return true }
        } else {
            // 有上一帧却无时间戳（调用方状态不完整）：宁可多发一次，不让组件冻结
            return true
        }
        if tempChangedEnough(previous.maxCelsius, next.maxCelsius, delta: tempDelta) { return true }
        if rpmChangedEnough(previous.fanAverageRPM, next.fanAverageRPM, delta: rpmDelta) { return true }
        return false
    }

    /// 双边取绝对值（降温 2° 与升温 2° 同样值得刷新）；nil↔有值视为出现/消失，本身就是可展示的变化
    private static func tempChangedEnough(_ previous: Double?, _ next: Double?, delta: Double) -> Bool {
        switch (previous, next) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) >= delta
        default: return true
        }
    }

    private static func rpmChangedEnough(_ previous: Int?, _ next: Int?, delta: Int) -> Bool {
        switch (previous, next) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) >= delta
        default: return true
        }
    }
}
