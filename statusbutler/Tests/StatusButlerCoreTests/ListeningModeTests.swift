import CoreAudio
import Testing

@testable import StatusButlerCore

// A14-δ 聆听模式：四态 raw 映射、lsms 掩码解析、可切换性规则，以及白名单未扩前的
// fail-closed 默认控制器。私有 HAL 路线（lstm/lsms）默认编译关闭，不在此覆盖。
@Suite struct ListeningModeTests {

    // MARK: - 四态 raw 映射（纯函数）

    @Test func rawValuesMapOntoFourStates() {
        // raw 值与 HAL `lstm` 整数同源（参考实现真机口径）
        #expect(ListeningModeRawValue.mode(fromRawValue: 1) == .off)
        #expect(ListeningModeRawValue.mode(fromRawValue: 2) == .noiseCancellation)
        #expect(ListeningModeRawValue.mode(fromRawValue: 3) == .transparency)
        #expect(ListeningModeRawValue.mode(fromRawValue: 4) == .adaptive)
    }

    @Test func unknownRawValuesFailClosedToNil() {
        // 0 = 未解析；越界值 = 本构建不认识的模式——都不猜，控制层不点亮选中态
        #expect(ListeningModeRawValue.mode(fromRawValue: 0) == nil)
        #expect(ListeningModeRawValue.mode(fromRawValue: 5) == nil)
        #expect(ListeningModeRawValue.mode(fromRawValue: 99) == nil)
        #expect(ListeningModeRawValue.mode(fromRawValue: UInt32.max) == nil)
    }

    // MARK: - 可切换性与支持掩码（纯函数）

    @Test func offIsObservableButNeverSelectable() {
        #expect(!ListeningMode.off.isUserSelectable)
        #expect(ListeningMode.noiseCancellation.isUserSelectable)
        #expect(ListeningMode.transparency.isUserSelectable)
        #expect(ListeningMode.adaptive.isUserSelectable)
        // off 在 lsms 里没有位：掩码从不表示它
        #expect(ListeningMode.off.supportBit == nil)
    }

    @Test func supportMaskParsesToDisplayOrderedModes() {
        // 位序与展示序解耦：输出恒按 displayOrder（NC/通透/自适应）
        #expect(ListeningModeSupport.availableModes(fromSupportMask: 0b111)
                == [.noiseCancellation, .transparency, .adaptive])
        #expect(ListeningModeSupport.availableModes(fromSupportMask: 0b101)
                == [.noiseCancellation, .adaptive])
        #expect(ListeningModeSupport.availableModes(fromSupportMask: 0b010)
                == [.transparency])
        // 空掩码 = 无控件可用
        #expect(ListeningModeSupport.availableModes(fromSupportMask: 0).isEmpty)
    }

    @Test func supportMaskDropsUnknownBitsWithoutGuessing() {
        // 未来系统加位（如 0b1000）：不浮出半接线的按钮，但调试日志能看见
        #expect(ListeningModeSupport.availableModes(fromSupportMask: 0b1000).isEmpty)
        #expect(ListeningModeSupport.hasUnknownBits(0b1000))
        #expect(ListeningModeSupport.hasUnknownBits(0b1111))
        #expect(!ListeningModeSupport.hasUnknownBits(0b111))
        #expect(!ListeningModeSupport.hasUnknownBits(0))
    }

    // MARK: - 默认控制器 fail-closed（红线四白名单未扩前的注入形态）

    @Test func unavailableControllerFailsClosedOnEverySurface() async {
        let controller = UnavailableListeningModeController()
        #expect(controller.read(deviceID: AudioDeviceID(42)) == nil)
        #expect(!controller.isSupported(.noiseCancellation, deviceID: AudioDeviceID(42)))
        #expect(!(await controller.set(.transparency, deviceID: AudioDeviceID(42))))
        #expect(!(await controller.set(.off, deviceID: AudioDeviceID(42))))
    }
}
