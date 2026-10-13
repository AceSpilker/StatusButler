import Foundation
import IOKit
import Testing

@testable import StatusButlerCore

// A14-δ 蓝牙操作引擎：HID 确认矩阵、地址归一、IOReturn→Bool 状态映射（假句柄）、
// 注入 resolver 的 async 全链与坏地址短路。IOBluetooth 真机路径不进测试
// （阻塞往返 bluetoothd），live 冒烟归接线层。
@Suite struct BluetoothOperationsTests {

    // MARK: - HID 确认矩阵（纯函数）

    @Test func hidConfirmationMatrix() {
        // 输入面设备：连接即接管键盘/指针，一律要确认
        #expect(BluetoothHIDConfirmationModel.needsConfirmation(.keyboard))
        #expect(BluetoothHIDConfirmationModel.needsConfirmation(.mouse))
        #expect(BluetoothHIDConfirmationModel.needsConfirmation(.trackpad))
        #expect(BluetoothHIDConfirmationModel.needsConfirmation(.gamepad))
        // 音频/穿戴/未知：连错只是没声音，不弹确认
        #expect(!BluetoothHIDConfirmationModel.needsConfirmation(.headphone))
        #expect(!BluetoothHIDConfirmationModel.needsConfirmation(.speaker))
        #expect(!BluetoothHIDConfirmationModel.needsConfirmation(.wearable))
        #expect(!BluetoothHIDConfirmationModel.needsConfirmation(.other))
    }

    // MARK: - 地址归一（纯函数）

    @Test func addressNormalizationCanonicalizesSeparatorAndCase() {
        // 冒号大写（UI/剪贴板形态）→ 短横线小写（addressString 键形态）
        #expect(BluetoothDeviceAddress.normalized("AC:90:85:C2:9C:1F") == "ac-90-85-c2-9c-1f")
        // 已是规范形态：原样通过
        #expect(BluetoothDeviceAddress.normalized("ac-90-85-c2-9c-1f") == "ac-90-85-c2-9c-1f")
        // 首尾空白容忍
        #expect(BluetoothDeviceAddress.normalized("  AC:90:85:C2:9C:1F\n") == "ac-90-85-c2-9c-1f")
    }

    @Test func addressNormalizationRejectsMalformedAddresses() {
        // 空/空白/长度不对/非十六进制 → ""（调用方据此短路，不进 resolver）
        #expect(BluetoothDeviceAddress.normalized("") == "")
        #expect(BluetoothDeviceAddress.normalized("   ") == "")
        #expect(BluetoothDeviceAddress.normalized("ac-90-85") == "")
        #expect(BluetoothDeviceAddress.normalized("ac-90-85-c2-9c-1f-00") == "")
        #expect(BluetoothDeviceAddress.normalized("zz-90-85-c2-9c-1f") == "")
    }

    // MARK: - IOReturn 状态映射（假句柄）

    /// @unchecked Sendable 安全：两个 let 存储只读，捕获进 @Sendable resolver 无竞态面
    private final class FakeHandle: BluetoothDeviceHandle, @unchecked Sendable {
        let connectResult: IOReturn
        let disconnectResult: IOReturn

        init(connectResult: IOReturn, disconnectResult: IOReturn) {
            self.connectResult = connectResult
            self.disconnectResult = disconnectResult
        }

        func performConnect() -> IOReturn { connectResult }
        func performDisconnect() -> IOReturn { disconnectResult }
    }

    @Test func outcomeMapsIOReturnStatusPerDirection() {
        let happy = FakeHandle(connectResult: kIOReturnSuccess, disconnectResult: kIOReturnSuccess)
        #expect(IOBluetoothOperations.outcome(resolved: happy, connect: true))
        #expect(IOBluetoothOperations.outcome(resolved: happy, connect: false))

        // 硬错误按方向各自映射，不串方向
        let failing = FakeHandle(connectResult: kIOReturnError, disconnectResult: kIOReturnNoDevice)
        #expect(!IOBluetoothOperations.outcome(resolved: failing, connect: true))
        #expect(!IOBluetoothOperations.outcome(resolved: failing, connect: false))

        // kIOReturnBusy 等中间态不当成功：连接是否真建立以连接态快照为准
        let busy = FakeHandle(connectResult: kIOReturnBusy, disconnectResult: kIOReturnSuccess)
        #expect(!IOBluetoothOperations.outcome(resolved: busy, connect: true))
        #expect(IOBluetoothOperations.outcome(resolved: busy, connect: false))
    }

    @Test func outcomeFailsClosedWithoutDeviceHandle() {
        // 设备已解除配对/地址不存在：resolver 给 nil → 双向都 false，不猜
        #expect(!IOBluetoothOperations.outcome(resolved: nil, connect: true))
        #expect(!IOBluetoothOperations.outcome(resolved: nil, connect: false))
    }

    // MARK: - async 全链（注入 resolver）

    /// @Sendable resolver 里记录调用需要串行化——NSLock 小盒子，测试专用
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func record(_ address: String) {
            lock.lock()
            calls.append(address)
            lock.unlock()
        }
        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    @Test func asyncOperationsResolveThroughInjectedResolver() async {
        let happy = FakeHandle(connectResult: kIOReturnSuccess, disconnectResult: kIOReturnSuccess)
        let log = CallLog()
        let operations = IOBluetoothOperations(resolve: { address in
            log.record(address)
            return address == "ac-90-85-c2-9c-1f" ? happy : nil
        })
        #expect(await operations.connect(address: "ac-90-85-c2-9c-1f"))
        #expect(await operations.disconnect(address: "ac-90-85-c2-9c-1f"))
        // 地址不在配对表：nil → false（设备缺失路径）
        #expect(!(await operations.connect(address: "00-11-22-33-44-55")))
        #expect(log.recorded == [String](repeating: "ac-90-85-c2-9c-1f", count: 2) + ["00-11-22-33-44-55"])
    }

    @Test func malformedAddressShortCircuitsBeforeResolver() async {
        // 坏地址在 resolver 之前挡下：默认 resolver 是同步往返 bluetoothd 的贵调用，
        // 空/畸形地址不值得一次系统查询
        let log = CallLog()
        let operations = IOBluetoothOperations(resolve: { address in
            log.record(address)
            return FakeHandle(connectResult: kIOReturnSuccess, disconnectResult: kIOReturnSuccess)
        })
        #expect(!(await operations.connect(address: "")))
        #expect(!(await operations.disconnect(address: "garbage")))
        #expect(log.recorded.isEmpty)
    }
}
