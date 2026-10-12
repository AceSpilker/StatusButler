import Testing
import Foundation
@testable import StatusButlerCore

// T-023: 蓝牙监控读取路径 —— CoD→种类纯函数映射（无硬件可测）+ 真机冒烟（只断言形态）
@Suite struct BluetoothMonitorTests {
    // MARK: - kind(ofDeviceClass:) 纯函数映射

    @Test func keyboardMapsFromPeripheralKeyboardCategory() {
        // Apple Wireless Keyboard 实测 CoD 0x2540 → major 5 / minor 0x10
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x10)) == .keyboard)
        // 组合设备（键盘+指向，bits 7-6 = 11）以键盘为主形态
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x30)) == .keyboard)
    }

    @Test func mouseMapsFromPeripheralPointingCategory() {
        // Magic Mouse 实测 CoD 0x2580 → major 5 / minor 0x20（指向类，子型任意）
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x20)) == .mouse)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x25)) == .mouse)
    }

    @Test func gamepadMapsFromPeripheralSubtype() {
        // 手柄只在"非键盘非指向"类别下凭子型识别（bits 5-2）：Gamepad=0x02 / Joystick=0x01
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x02)) == .gamepad)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x01)) == .gamepad)
        // 同类别其余子型（遥控器/数位板）不是手柄
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x05, minor: 0x03)) == .other)
    }

    @Test func headphoneMapsFromAudioHeadsetVariants() {
        // 实测三类贴耳设备：头戴耳机 Headphones=0x06、单耳 Headset=0x01、免提 HandsFree=0x02
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x06)) == .headphone)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x01)) == .headphone)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x02)) == .headphone)
        // 同 major 下的麦克风不归耳机
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x04)) == .other)
    }

    @Test func speakerMapsFromAudioLoudspeakerVariants() {
        // Loudspeaker=0x05 / Portable=0x07 / HiFi=0x0A / 显示器自带喇叭=0x0F
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x05)) == .speaker)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x04, minor: 0x0A)) == .speaker)
    }

    @Test func wearableMapsFromWearableMajor() {
        // 穿戴 major 0x07 下手表/眼镜等所有 minor 都归穿戴
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x07, minor: 0x01)) == .wearable)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x07, minor: 0x05)) == .wearable)
    }

    @Test func unmappedMajorsFallToOther() {
        // 未覆盖域：智能手机(major 2) / 未分类(0x1F)；以及实测 CoD=0 的 BLE 配对件（类码缺失不猜）
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x02, minor: 0x03)) == .other)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x1F, minor: 0x00)) == .other)
        #expect(BluetoothDeviceKind.kind(ofDeviceClass: (major: 0x00, minor: 0x00)) == .other)
    }

    // MARK: - live 冒烟

    @Test func liveReadReturnsWellFormedSnapshot() async {
        // 冒烟只验形态与去重，不断言具体设备：无蓝牙模块的机器（CI/台式）返回空也必须通过
        let devices = await BluetoothMonitor().read()
        #expect(devices.allSatisfy { !$0.address.isEmpty })
        let addresses = Set(devices.map(\.address))
        #expect(addresses.count == devices.count)
    }

    @Test func deviceInfoValueSemantics() {
        // 值类型折叠语义：nil 名称折叠空串，等值比较按全字段
        let a = BluetoothDeviceInfo(name: "", address: "aa-bb", kind: .headphone, isConnected: false)
        let b = BluetoothDeviceInfo(name: "", address: "aa-bb", kind: .headphone, isConnected: false)
        #expect(a == b)
        #expect(a != BluetoothDeviceInfo(name: "", address: "aa-bb", kind: .headphone, isConnected: true))
    }
}
