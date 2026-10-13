import Foundation
import Testing

@testable import StatusButlerCore

// A14-β 弹层全量·服务层纯函数测试：脚本串/节流决策/滚动方向/电池映射/HID 状态机/
// 动作徽标/体检色档/扫描排序/地址格式化/深链串面——全部零系统调用
@Suite struct PanelServicesTests {

    // MARK: - 音量 AppleScript 生成串（不执行）

    @Test func volumeScriptClampsAndPinsExactString() {
        #expect(VolumeScript.outputVolumeScript(for: 42) == "set volume output volume 42")
        #expect(VolumeScript.outputVolumeScript(for: 0) == "set volume output volume 0")
        #expect(VolumeScript.outputVolumeScript(for: 100) == "set volume output volume 100")
        // 越界一律钳制进串，杜绝把非法档位交给 AppleScript
        #expect(VolumeScript.outputVolumeScript(for: 120) == "set volume output volume 100")
        #expect(VolumeScript.outputVolumeScript(for: -7) == "set volume output volume 0")
        #expect(VolumeScript.toggleMuteScript == "set volume output muted (not (output muted))")
    }

    @Test func volumeThrottleFirstWriteIsImmediateThenDeferredInsideWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // 首写无历史 → 立即
        let first = VolumeThrottle.decide(lastWriteAt: nil, now: t0, minInterval: 0.2)
        #expect(first.writeNow)
        #expect(first.flushAfter == nil)

        // 窗口内 → 延迟冲刷，延迟 = 补足窗口的余量
        let inside = VolumeThrottle.decide(lastWriteAt: t0, now: t0.addingTimeInterval(0.05), minInterval: 0.2)
        #expect(!inside.writeNow)
        #expect(abs((inside.flushAfter ?? -1) - 0.15) < 0.0001)

        // 窗口外 → 再次立即
        let outside = VolumeThrottle.decide(lastWriteAt: t0, now: t0.addingTimeInterval(0.2), minInterval: 0.2)
        #expect(outside.writeNow)
    }

    @Test func scrollVolumeDirectionFollowsNaturalScrollingToggle() {
        // 自然滚动（默认）：手指上扫（deltaY<0）调大，下扫调小——iOS 选择器同感
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: -8, naturalScrolling: true) > 0)
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: 8, naturalScrolling: true) < 0)
        // 传统滚动：滚轮上滚（deltaY>0）调大
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: 8, naturalScrolling: false) > 0)
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: -8, naturalScrolling: false) < 0)
        // 步进与钳制
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: -8, naturalScrolling: true, step: 5) == 5)
        #expect(ScrollVolumeMapping.apply(delta: 30, toLevel: 90) == 100)
        #expect(ScrollVolumeMapping.apply(delta: -30, toLevel: 10) == 0)
        #expect(ScrollVolumeMapping.volumeDelta(scrollDeltaY: 0, naturalScrolling: true) == 0)
    }

    @Test func volumeDisplayPrefersOverrideAndKeepsMutedFlag() {
        let snapshot = VolumeState(level: 20, isMuted: true)
        #expect(VolumeDisplay.resolve(snapshot: snapshot, override: 55)
                == VolumeState(level: 55, isMuted: true))
        #expect(VolumeDisplay.resolve(snapshot: snapshot, override: nil) == snapshot)
        #expect(VolumeDisplay.resolve(snapshot: snapshot, override: 300).level == 100)
    }

    // MARK: - 电池详情映射（假 IORegistry dict）

    @Test func batteryDetailsMappingReadsAppleSmartBatteryKeysFromFakeDict() {
        let dict: [String: Any] = [
            "CycleCount": 312,
            "MaxCapacity": 4_802,
            "DesignCapacity": 5_103,
            "Voltage": 12_160,
            "Amperage": -1_540,  // Apple 约定负值 = 充电
            "ExternalConnected": true,
            "IsCharging": true,
            "UnrelatedKey": "ignored",
        ]
        let details = BatteryDetailsMapping.details(from: dict)
        #expect(details.cycleCount == 312)
        #expect(details.maxCapacity == 4_802)
        #expect(details.designCapacity == 5_103)
        #expect(details.voltageMillivolts == 12_160)
        #expect(details.amperageMilliamps == -1_540)
        #expect(details.externalConnected)
        #expect(details.isCharging)

        // 键缺测 → nil / false，不虚构
        let sparse = BatteryDetailsMapping.details(from: ["CycleCount": 5])
        #expect(sparse.cycleCount == 5)
        #expect(sparse.maxCapacity == nil)
        #expect(!sparse.externalConnected)
    }

    @Test func batteryHealthPercentBoundaries() {
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: 4_802, designCapacity: 5_103) == 94)
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: 5_103, designCapacity: 5_103) == 100)
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: nil, designCapacity: 5_103) == nil)
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: 4_802, designCapacity: nil) == nil)
        // 异常容量防御：设计非正/超界结果都收敛进合法域
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: 4_802, designCapacity: 0) == nil)
        #expect(BatteryDetailsMapping.healthPercent(maxCapacity: 9_999, designCapacity: 5_103) == 100)
    }

    @Test func batteryElectricalTextsFollowAppleSignConvention() {
        // 充电：Amperage 为负 → 功率为负 → 文案翻正归充电
        #expect((BatteryDetailsMapping.powerWatts(voltageMillivolts: 12_160, amperageMilliamps: -1_540) ?? 1) < 0)
        #expect(BatteryDetailsMapping.powerText(voltageMillivolts: 12_160, amperageMilliamps: -1_540).hasPrefix("充电"))
        #expect(BatteryDetailsMapping.powerText(voltageMillivolts: 11_800, amperageMilliamps: 2_100).hasPrefix("放电"))
        #expect(BatteryDetailsMapping.powerText(voltageMillivolts: nil, amperageMilliamps: 2_100) == "—")
        #expect(BatteryDetailsMapping.voltageText(12_160) == "12.16 V")
        #expect(BatteryDetailsMapping.voltageText(nil) == "—")
    }

    @Test func batteryHealthTierBoundaries() {
        #expect(BatteryHealthTier.tier(forHealthPercent: 80) == .normal)
        #expect(BatteryHealthTier.tier(forHealthPercent: 100) == .normal)
        #expect(BatteryHealthTier.tier(forHealthPercent: 79) == .attention)
        #expect(BatteryHealthTier.tier(forHealthPercent: 60) == .attention)
        #expect(BatteryHealthTier.tier(forHealthPercent: 59) == .replace)
        #expect(BatteryHealthTier.tier(forHealthPercent: nil) == nil)
    }

    // MARK: - HID 断开二次确认状态机

    @Test func hidConfirmRequiresSecondTapWithinTimeout() {
        var model = HIDConfirmModel()
        let t0 = Date(timeIntervalSince1970: 2_000)
        // 第一击：只武装（mutating 方法先落局部值再断言——#expect 宏无法捕获 mutating 调用）
        let first = model.tapDisconnect(address: "kb-1", now: t0)
        #expect(!first)
        #expect(model.armedAddress == "kb-1")
        // 第二击（窗口内）：确认执行并清空
        let second = model.tapDisconnect(address: "kb-1", now: t0.addingTimeInterval(1))
        #expect(second)
        #expect(model.armedAddress == nil)
        // 再来一次又回到武装
        let third = model.tapDisconnect(address: "kb-1", now: t0.addingTimeInterval(2))
        #expect(!third)
    }

    @Test func hidConfirmExpiresAfterTimeoutAndSwitchesTarget() {
        var model = HIDConfirmModel()
        let t0 = Date(timeIntervalSince1970: 3_000)
        let first = model.tapDisconnect(address: "kb-1", now: t0)
        #expect(!first)
        // 超时后再击：重新武装而非直接执行
        let expired = model.tapDisconnect(address: "kb-1", now: t0.addingTimeInterval(HIDConfirmModel.defaultTimeout + 0.1))
        #expect(!expired)
        #expect(model.armedAddress == "kb-1")
        // 点击另一设备：换目标重新武装
        let switched = model.tapDisconnect(address: "mouse-2", now: t0.addingTimeInterval(HIDConfirmModel.defaultTimeout + 0.2))
        #expect(!switched)
        #expect(model.armedAddress == "mouse-2")
        let confirmed = model.tapDisconnect(address: "mouse-2", now: t0.addingTimeInterval(HIDConfirmModel.defaultTimeout + 0.3))
        #expect(confirmed)
        // 设备离场 → 武装失效
        model.invalidate(address: "mouse-2")
        #expect(model.armedAddress == nil)
    }

    @Test func hidConfirmKindsCoverInputDevicesOnly() {
        #expect(HIDConfirmModel.isHIDKind(.keyboard))
        #expect(HIDConfirmModel.isHIDKind(.mouse))
        #expect(HIDConfirmModel.isHIDKind(.trackpad))
        #expect(HIDConfirmModel.isHIDKind(.gamepad))
        #expect(!HIDConfirmModel.isHIDKind(.headphone))
        #expect(!HIDConfirmModel.isHIDKind(.speaker))
        #expect(!HIDConfirmModel.isHIDKind(.wearable))
        #expect(!HIDConfirmModel.isHIDKind(.other))
    }

    // MARK: - 动作行 availability 渲染数据

    @Test func actionStripStylingMapsAvailabilityToBadgeAndDisabled() {
        #expect(ActionStripStyling.badgeText(for: .available) == nil)
        #expect(!ActionStripStyling.isDisabled(for: .available))
        #expect(ActionStripStyling.badgeText(for: .needsPermission("辅助功能")) == "需辅助功能")
        #expect(!ActionStripStyling.isDisabled(for: .needsPermission("辅助功能")))
        #expect(ActionStripStyling.badgeText(for: .deepLinkOnly) == "跳系统")
        #expect(!ActionStripStyling.isDisabled(for: .deepLinkOnly))
        // 只有"本机不支持"灰显——诚实分级：可引导的可点，不可执行的绝不装可点
        #expect(ActionStripStyling.badgeText(for: .unavailableOnSystem) == "本机不支持")
        #expect(ActionStripStyling.isDisabled(for: .unavailableOnSystem))
    }

    // MARK: - 体检色档

    @Test func healthScoreTierBoundaries() {
        #expect(HealthScoreTier.tier(forScore: 100) == .good)
        #expect(HealthScoreTier.tier(forScore: 85) == .good)
        #expect(HealthScoreTier.tier(forScore: 84) == .fair)
        #expect(HealthScoreTier.tier(forScore: 60) == .fair)
        #expect(HealthScoreTier.tier(forScore: 59) == .poor)
        #expect(HealthScoreTier.tier(forScore: 0) == .poor)
    }

    // MARK: - 附近网络排序与降级显示

    @Test func nearbyNetworkOrderSortsBySignalThenNameStably() {
        let networks = [
            NearbyNetwork(ssid: "弱网", bssid: "aa:1", rssi: -80, isSecure: true),
            NearbyNetwork(ssid: "强网", bssid: "aa:2", rssi: -42, isSecure: true),
            NearbyNetwork(ssid: "A 同格", bssid: "aa:3", rssi: -60, isSecure: false),
            NearbyNetwork(ssid: "B 同格", bssid: "aa:4", rssi: -60, isSecure: true),
        ]
        let ordered = NearbyNetworkOrder.ordered(networks)
        #expect(ordered.map(\.ssid) == ["强网", "A 同格", "B 同格", "弱网"])
        // 同输入同输出（稳定排序）
        #expect(NearbyNetworkOrder.ordered(networks) == ordered)
    }

    @Test func nearbyNetworkDisplayNameFallsBackToBSSIDThenPlaceholder() {
        #expect(NearbyNetwork(ssid: "Home", bssid: "b:1", rssi: -50, isSecure: true).displayName == "Home")
        // 无定位授权：SSID 脱敏、BSSID 还在时降级显示 BSSID
        #expect(NearbyNetwork(ssid: nil, bssid: "aa:bb:cc", rssi: -50, isSecure: true).displayName == "aa:bb:cc")
        // 双脱敏 → 占位（不虚构网络名）
        #expect(NearbyNetwork(ssid: nil, bssid: nil, rssi: -50, isSecure: false).displayName == "隐藏网络")
        // 信号弧复用监控域门限（-55/-65/-75/-85）
        #expect(NearbyNetwork(ssid: nil, bssid: nil, rssi: -50, isSecure: false).signalBars == 4)
        #expect(NearbyNetwork(ssid: nil, bssid: nil, rssi: -90, isSecure: false).signalBars == 0)
    }

    // MARK: - 链路详情格式化

    @Test func interfaceAddressFormattingFiltersLoopbackAndLinkLocal() {
        let addresses = [
            InterfaceAddressInfo(name: "lo0", address: "127.0.0.1", family: .ipv4),
            InterfaceAddressInfo(name: "en0", address: "fe80::1a:2b", family: .ipv6),
            InterfaceAddressInfo(name: "en0", address: "192.168.1.5", family: .ipv4),
            InterfaceAddressInfo(name: "utun3", address: "10.8.0.2", family: .ipv4),
        ]
        let lines = LinkDetailsFormatting.addressLines(addresses)
        #expect(lines == ["en0 · 192.168.1.5", "utun3 · 10.8.0.2"])  // 回环与 fe80 滤除，utun 保留
    }

    @Test func linkDetailsFormattingSummarizesInterfacesAndFlags() {
        let details = ConnectionDetails(
            isSatisfied: true, isExpensive: true, isConstrained: true,
            isVPN: true, interfaceTypes: [.wifi, .other]
        )
        // 接口并排列按 rawValue 稳定排序（other < wifi）
        #expect(LinkDetailsFormatting.interfaceSummary(details: details) == "其他（隧道/VPN） + Wi-Fi")
        let flags = LinkDetailsFormatting.flags(details: details)
        #expect(flags.map(\.label) == ["可达", "VPN 隧道", "低数据模式", "计费链路"])
        #expect(flags.map(\.isOn) == [true, true, true, true])

        let offline = ConnectionDetails.offline
        #expect(LinkDetailsFormatting.interfaceSummary(details: offline) == "无活动接口")
        #expect(LinkDetailsFormatting.flags(details: offline).map(\.isOn) == [false, false, false, false])
    }

    // MARK: - 深链 URL 串

    @Test func deepLinkURLStringsArePinned() {
        #expect(PanelDeepLink.wifiSettingsURLString == "x-apple.systempreferences:com.apple.Wi-Fi")
        #expect(PanelDeepLink.batterySettingsURLString == "x-apple.systempreferences:com.apple.Battery")
        #expect(PanelDeepLink.wifiSettings.absoluteString == PanelDeepLink.wifiSettingsURLString)
    }

    @Test func healthRemediationLinksMapCheckIDsAndRefuseUnknowns() {
        #expect(PanelDeepLink.remediationURL(forCheckID: "filevault")?.absoluteString
                == PanelDeepLink.privacySecurityURLString)
        #expect(PanelDeepLink.remediationURL(forCheckID: "gatekeeper")?.absoluteString
                == PanelDeepLink.privacySecurityURLString)
        #expect(PanelDeepLink.remediationURL(forCheckID: "firewall")?.absoluteString
                == PanelDeepLink.networkSettingsURLString)
        #expect(PanelDeepLink.remediationURL(forCheckID: "softwareUpdate")?.absoluteString
                == PanelDeepLink.softwareUpdateURLString)
        // 未知检查项不给深链（"去修复"按钮随之隐藏，不跳错面板）
        #expect(PanelDeepLink.remediationURL(forCheckID: "mystery") == nil)
    }

    // MARK: - AirPods 三仓位展示

    @Test func airPodsSummaryListsPodsAndOmitsMissingCase() {
        let full = AirPodsBattery(left: 88, right: 76, case: 55)
        #expect(BluetoothPanelDisplay.airPodsSummary(full) == "左耳 88% · 右耳 76% · 充电盒 55%")
        let noCase = AirPodsBattery(left: 88, right: 76)
        #expect(BluetoothPanelDisplay.airPodsSummary(noCase) == "左耳 88% · 右耳 76%")
    }

    // MARK: - 槽位轮换（静态轮换器）

    @Test func staticSlotCyclerCyclesAndWraps() {
        let cycler = StaticSlotCycler(labels: ["音量", "时钟", "电池%"])
        #expect(cycler.currentLabel() == "音量")
        #expect(cycler.cycle() == "时钟")
        #expect(cycler.currentLabel() == "时钟")
        #expect(cycler.cycle() == "电池%")
        #expect(cycler.cycle() == "音量")  // 回绕
        // 空表不越界
        let empty = StaticSlotCycler(labels: [])
        #expect(empty.currentLabel() == "")
        #expect(empty.cycle() == "")
    }
}
