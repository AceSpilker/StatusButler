import AppKit
import Combine

// 菜单栏壳（A2·S3 初版）：订阅快照，状态不变不重绘；右键/点击菜单含退出
@MainActor
public final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: SystemStatusStore
    private let settings: SettingsStore
    private var localization: Localization
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private var lastRenderedScene: IconSceneState?
    private var lastRenderedInputs: (size: Double, dark: Bool)?
    private var lastFooter: SlotScene?
    private var lastGlow: Double??
    private var onTogglePopover: ((NSStatusBarButton) -> Void)?
    private var onOpenSettings: (() -> Void)?
    /// internal 供测试断言菜单标题随语言重建（@testable）
    lazy var menu: NSMenu = buildMenu()

    public init(
        store: SystemStatusStore,
        settings: SettingsStore,
        localization: Localization = Localization(language: .system)
    ) {
        self.store = store
        self.settings = settings
        self.localization = localization
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        super.init()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu  // configure() 接管后改为左键弹层/右键菜单
    }

    /// 集成接线：左键 → 弹层；菜单"设置…" → 设置窗口（未接线时保持纯菜单行为）
    public func configure(
        popoverToggle: @escaping (NSStatusBarButton) -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.onTogglePopover = popoverToggle
        self.onOpenSettings = openSettings
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown {
            menu.delegate = self
            statusItem.menu = menu
            sender.performClick(nil)
        } else {
            onTogglePopover?(sender)
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil  // 让回左键弹层通道
    }

    /// 订阅启动与渲染由组合根调度（避免 init 期触发链）
    /// 充电呼吸相位变化时仅更新图像（绕过三元组缓存的场景比较）
    public func renderGlow(_ glow: Double?) {
        render(snapshot: store.snapshot, iconSize: settings.menuBarIconSize, glow: glow)
    }

    public func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// 弹层锚点（Dock 点击接线，A2·S2）：菜单栏图标可见才有锚——
    /// dockOnly 隐藏期返回 nil，Dock 点击由组合根降级开设置（弹层无处锚定）
    public var anchorButton: NSStatusBarButton? {
        statusItem.isVisible ? statusItem.button : nil
    }

    /// 语言切换接线（组合根订阅 settings.appLanguage 后调）：三个菜单标题全部来自本地化表，
    /// 整体重建比逐项改题干净（菜单此刻未挂载——configure 后 statusItem.menu 恒 nil，直到右键）
    public func updateLocalization(_ newLocalization: Localization) {
        localization = newLocalization
        menu = buildMenu()
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

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    private func buildMenu() -> NSMenu {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return Self.makeMenu(localization: localization, version: version, settingsTarget: self)
    }

    /// 菜单构建（internal 供测试断言标题取自本地化表）：version 显式注入避免测试读真 Bundle；
    /// settingsTarget 由实例接线传入，测试传 nil（action 选择子照常携带）
    static func makeMenu(
        localization: Localization,
        version: String,
        settingsTarget: AnyObject? = nil
    ) -> NSMenu {
        let menu = NSMenu()
        let versionItem = NSMenuItem(
            title: String(format: localization.string(.menuVersion), version),
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        let settingsItem = NSMenuItem(
            title: localization.string(.menuSettings),
            action: #selector(StatusBarController.settingsClicked),
            keyEquivalent: ","
        )
        settingsItem.target = settingsTarget
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: localization.string(.menuQuit),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        return menu
    }
}
