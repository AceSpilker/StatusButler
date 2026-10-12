import AppKit
import Combine

// 菜单栏壳（A2·S3 初版）：订阅快照，状态不变不重绘；右键/点击菜单含退出
@MainActor
public final class StatusBarController {
    private let store: SystemStatusStore
    private let settings: SettingsStore
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private var lastRenderedScene: IconSceneState?
    private var lastRenderedInputs: (size: Double, dark: Bool)?

    public init(store: SystemStatusStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        statusItem.button?.imagePosition = .imageOnly
        buildMenu()
    }

    /// 订阅启动与渲染由组合根调度（避免 init 期触发链）
    public func startObserving() {
        guard cancellables.isEmpty else { return }
        bind()
        render(
            snapshot: store.snapshot,
            iconSize: settings.menuBarIconSize
        )
    }

    private func bind() {
        Publishers.CombineLatest(
            store.$snapshot.removeDuplicates(),
            settings.$menuBarIconSize.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshot, iconSize in
            self?.render(snapshot: snapshot, iconSize: iconSize)
        }
        .store(in: &cancellables)
    }

    private func render(snapshot: StatusSnapshot, iconSize: Double) {
        let scene = IconSceneState.from(snapshot)
        let dark = NSApp?.effectiveAppearance.name == .darkAqua
        // 渲染缓存 key：场景 + 尺寸 + 外观 三元组不变即跳过（B1 铁律三）
        if scene == lastRenderedScene,
           lastRenderedInputs?.size == iconSize,
           lastRenderedInputs?.dark == dark {
            return
        }
        lastRenderedScene = scene
        lastRenderedInputs = (iconSize, dark)
        statusItem.button?.image = StatusIconRenderer.image(
            scene: scene,
            pointSize: iconSize,
            dark: dark
        )
    }

    private func buildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let versionItem = NSMenuItem(
            title: "状态管家 v\(version)", action: nil, keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "退出状态管家", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        statusItem.menu = menu
    }
}
