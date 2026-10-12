import AppKit
import Combine

// 激活策略 + Dock 图标控制（A2·S2）：位置开关变化 → 策略切换 + Dock 图标渲染
@MainActor
public final class AppIconController {
    private let store: SystemStatusStore
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var lastKey: (scene: IconSceneState, placement: AppIconPlacement, dark: Bool)?

    public init(store: SystemStatusStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    public func start() {
        Publishers.CombineLatest(
            store.$snapshot.removeDuplicates(),
            settings.$appIconPlacement.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshot, placement in
            self?.apply(snapshot: snapshot, placement: placement)
        }
        .store(in: &cancellables)
    }

    public func stop() {
        cancellables.removeAll()
    }

    private func apply(snapshot: StatusSnapshot, placement: AppIconPlacement) {
        let policy: NSApplication.ActivationPolicy = placement.usesRegularPolicy ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)

        guard placement.showsDockIcon else {
            NSApplication.shared.dockTile.contentView = nil
            lastKey = nil
            return
        }
        let scene = IconSceneState.from(snapshot)
        let dark = NSApp?.effectiveAppearance.name == .darkAqua
        if lastKey?.scene == scene, lastKey?.placement == placement, lastKey?.dark == dark {
            return
        }
        lastKey = (scene, placement, dark)
        NSApplication.shared.applicationIconImage = DockIconRenderer.image(
            scene: scene, dark: dark
        )
    }
}
