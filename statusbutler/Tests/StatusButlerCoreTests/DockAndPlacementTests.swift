import Testing
import AppKit
@testable import StatusButlerCore

// T-012: 位置语义 / 策略映射 / Dock 渲染冒烟 / 设置持久化
@MainActor
@Suite struct DockAndPlacementTests {
    @Test func placementSemantics() {
        #expect(AppIconPlacement.menuBarOnly.showsMenuBarIcon)
        #expect(!AppIconPlacement.menuBarOnly.showsDockIcon)
        #expect(!AppIconPlacement.dockOnly.showsMenuBarIcon)
        #expect(AppIconPlacement.both.showsDockIcon)
        #expect(AppIconPlacement.menuBarOnly.usesRegularPolicy == false)
        #expect(AppIconPlacement.both.usesRegularPolicy)
    }

    @Test func placementPersists() {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = SettingsStore(defaults: defaults)
        #expect(store.appIconPlacement == .menuBarOnly)
        store.appIconPlacement = .both
        #expect(SettingsStore(defaults: defaults).appIconPlacement == .both)
    }

    @Test func dockRendererSmoke() {
        let image = DockIconRenderer.image(
            scene: IconSceneState.empty, pointSize: 128, dark: true
        )
        #expect(Double(image.size.width) == 128)
        #expect(image.tiffRepresentation != nil)
    }
}
