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
    private var lastFooter: SlotScene?
    private var lastGlow: Double??

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
    /// 充电呼吸相位变化时仅更新图像（绕过三元组缓存的场景比较）
    public func renderGlow(_ glow: Double?) {
        render(snapshot: store.snapshot, iconSize: settings.menuBarIconSize, glow: glow)
    }

    public func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

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

    private func render(snapshot: StatusSnapshot, iconSize: Double, glow: Double? = nil) {
        let scene = IconSceneState.from(snapshot)
        let dark = NSApp?.effectiveAppearance.name == .darkAqua
        let composer = SlotComposer(selectedID: settings.footerSlotID)
        let footer = composer.footer(snapshot: snapshot)
        // 渲染缓存 key：场景+尺寸+外观+槽位+呼吸相位（呼吸激活时相位连续变化，直接重绘）
        if glow == nil, scene == lastRenderedScene,
           lastRenderedInputs?.size == iconSize,
           lastRenderedInputs?.dark == dark,
           footer == lastFooter {
            return
        }
        lastRenderedScene = scene
        lastRenderedInputs = (iconSize, dark)
        lastFooter = footer
        statusItem.button?.image = StatusIconRenderer.image(
            scene: scene,
            pointSize: iconSize,
            dark: dark,
            chargingGlow: glow,
            footerSlot: footer
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
