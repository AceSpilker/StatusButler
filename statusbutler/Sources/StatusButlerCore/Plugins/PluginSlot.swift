import Foundation

// E16·SP-01：插件接入 E1 槽位体系。SlotSource.scene() 是同步协议，
// 而沙盒执行最长 2s——绝不能阻塞渲染线程，故 scene() 只做"到期判定 + 后台触发"，
// 立即返回缓存；执行结果经 slotScene 决策后写回缓存。
// 注册进 SlotRegistry 由集成方完成（本文件不触碰 SlotSystem.swift）。

/// 脚本插件槽位源。
public struct PluginSlot: SlotSource {
    public let id: String   // "plugin:" + manifest.id，与内置源命名空间隔离

    private let manifest: PluginManifest
    private let scriptPath: String
    private let runner: PluginRunner
    private let cache: SceneCache

    public init(manifest: PluginManifest, scriptPath: String, runner: PluginRunner) {
        self.id = "plugin:" + manifest.id
        self.manifest = manifest
        self.scriptPath = scriptPath
        self.runner = runner
        self.cache = SceneCache()
    }

    public func scene(snapshot: StatusSnapshot, now: Date) -> SlotScene? {
        // 有人看才运行：只有渲染拉取场景时才调度执行（能效铁律）；
        // refreshHint 带 20% 提前量（间隔/5 容忍），避免恰好到期时空档闪烁。
        // 判定与占位分两步锁：markRefreshStarted 在锁内双检 inFlight，
        // 并发拉取只放行一次执行
        guard
            cache.shouldRefresh(hint: TimeInterval(manifest.refreshHintSeconds), now: now),
            cache.markRefreshStarted(now: now)
        else {
            return cache.current
        }
        let runner = self.runner
        let manifest = self.manifest
        let path = self.scriptPath
        let cache = self.cache
        Task.detached(priority: .utility) {
            let output = await runner.run(manifest: manifest, scriptPath: path)
            cache.apply(output: output)
        }
        return cache.current
    }

    /// 场景决策表（纯函数，钉死测试）：
    /// 成功→新场景；失败/超时→沿用上次成功（陈旧标注策略见下）；停用→nil。
    ///
    /// 陈旧标注策略：失败/超时时显示旧值好过槽位闪烁消失——用户看一个迟到的
    /// "128G"比看一个凭空消失的槽位更能理解发生了什么；持续劣化由三连击
    /// 停用兜底（disabled 分支才真正撤槽）。此后 E6 若有"数据龄"徽标可再升级。
    public static func slotScene(from previous: SlotScene?, output: PluginOutput) -> SlotScene? {
        switch output {
        case .success(let scene):
            return scene
        case .failed, .timeout:
            return previous
        case .disabled:
            return nil
        }
    }
}

/// 槽位缓存：最近成功场景 + 刷新调度状态。
/// 锁纪律：全部可变态（current/lastRefresh/inFlight/disabled）由 lock 保护，
/// 无嵌套锁、锁内不做任何回调或 IO。
final class SceneCache: @unchecked Sendable {
    private let lock = NSLock()
    private var currentScene: SlotScene?
    private var lastRefresh: Date?
    private var inFlight = false
    private var disabled = false

    var current: SlotScene? { lock.withLock { currentScene } }

    /// 到期判定：未停用、无在途执行、距上次发起 ≥ 80% 提示间隔（首次立即到期）。
    func shouldRefresh(hint: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            if disabled || inFlight { return false }
            guard let last = lastRefresh else { return true }
            return now.timeIntervalSince(last) >= hint * 0.8
        }
    }

    /// 占位发起：锁内双检 inFlight，并发拉取只放行第一个；返回 false = 已有执行在途。
    func markRefreshStarted(now: Date) -> Bool {
        lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            lastRefresh = now
            return true
        }
    }

    /// 决策复用 PluginSlot.slotScene 纯函数，保证 e2e 行为与决策表一致。
    func apply(output: PluginOutput) {
        lock.withLock {
            inFlight = false
            if case .disabled = output { disabled = true }
            currentScene = PluginSlot.slotScene(from: currentScene, output: output)
        }
    }
}

// MARK: - 插件目录扫描（SP-01/SP-03）

/// 扫描插件根目录：每个子目录 = 一个插件（manifest.json + script.sh）。
/// 目录可注入（测试传 /tmp fixture 根，线上传默认根），损坏/越权目录一律跳过。
public enum PluginDirectory {
    public static let manifestFileName = "manifest.json"
    public static let scriptFileName = "script.sh"

    /// ~/Library/Application Support/StatusButler/plugins/
    /// 插件由用户主动放置，引擎不做任何下载；扫描只读，不创建目录。
    public static func defaultRoot() -> URL {
        // urls(for:) 不抛错；拿不到应用支持目录时退回 ~/Library 路径拼接（只读扫描用）
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StatusButler/plugins", isDirectory: true)
    }

    /// 返回有效插件 (manifest, scriptURL)，按目录名排序保证稳定顺序；
    /// 重复 id 只收第一个（防同 id 插件撞槽位 key "plugin:"+id）。
    public static func scan(root: URL) -> [(manifest: PluginManifest, scriptURL: URL)] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var seen = Set<String>()
        var results: [(manifest: PluginManifest, scriptURL: URL)] = []
        for dir in entries.sorted(by: { $0.path < $1.path }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let manifestURL = dir.appendingPathComponent(manifestFileName)
            let scriptURL = dir.appendingPathComponent(scriptFileName)
            // script.sh 由解释器读取执行，不需 +x，可读即可
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
                manifest.isValid,
                fm.isReadableFile(atPath: scriptURL.path)
            else { continue }
            guard seen.insert(manifest.id).inserted else { continue }
            results.append((manifest, scriptURL))
        }
        return results
    }
}
