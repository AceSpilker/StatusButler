import Foundation
import Testing

@testable import StatusButlerCore

// A14-δ DDC 音量：VCP 0x62 帧构造字面钉死（ddcctl 社区口径验算）、音量路由决策表
// （外接/内建/未知 + 注入判定闭包）、客户端扩展的静默降级路径。
@Suite struct DDCVolumeTests {

    // MARK: - 音量帧构造（字面钉死）

    @Test func volumeRegisterIsPinnedToSpeakerVCP() {
        // MCCS speaker volume = 0x62，与参考实现 DDCDisplayTransport 同码
        #expect(DDCFrame.volumeRegister == 0x62)
    }

    @Test func volumeFramesMatchCommunityChecksumConventions() {
        // 设值：寄存器 0x62 写 37(0x25)——校验和 0x50+0x82+0x03+0x62+0x00+0x25=0x15C→0x5C
        #expect(DDCFrame.setValueCommand(register: DDCFrame.volumeRegister, value: 37)
                == [0x51, 0x82, 0x03, 0x62, 0x00, 0x25, 0x5C])
        // 设值：寄存器 0x62 写 100(0x64)——校验和 0x50+0x82+0x03+0x62+0x00+0x64=0x19B→0x9B
        #expect(DDCFrame.setValueCommand(register: DDCFrame.volumeRegister, value: 100)
                == [0x51, 0x82, 0x03, 0x62, 0x00, 0x64, 0x9B])
        // 设值：寄存器 0x62 写 0——校验和 0x50+0x82+0x03+0x62=0x137→0x37
        #expect(DDCFrame.setValueCommand(register: DDCFrame.volumeRegister, value: 0)
                == [0x51, 0x82, 0x03, 0x62, 0x00, 0x00, 0x37])
        // 读值：寄存器 0x62 请求——校验和 0x50+0x82+0x01+0x62=0x135→0x35
        #expect(DDCFrame.getValueCommand(register: DDCFrame.volumeRegister)
                == [0x51, 0x82, 0x01, 0x62, 0x35])
    }

    // MARK: - 音量路由决策表（纯函数）

    @Test func routingTableForExternalBuiltInAndUnknownOutputs() {
        // 外接屏（ModelUID 含 Display，大小写不敏感）+ DDC 可用 → 路由 DDC
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "DisplayPort", ddcAvailable: true)
                == .ddc)
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "DELL U2723QE display", ddcAvailable: true)
                == .ddc)
        // 内建扬声器 → 恒系统音量
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "MacBook Pro Speakers", ddcAvailable: true)
                == .system)
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "内建扬声器", ddcAvailable: true)
                == .system)
        // 未知（无默认设备/读不到 ModelUID/空白串）→ fail-safe 系统音量
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: nil, ddcAvailable: true) == .system)
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "", ddcAvailable: true) == .system)
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "   \n ", ddcAvailable: true) == .system)
        // 判定为外接屏但 DDC 通道不可用（dlsym 失败/沙盒）→ 降级回系统音量，不硬路由
        #expect(DDCRouting.volumeRoute(defaultOutputModelUID: "DisplayPort", ddcAvailable: false)
                == .system)
    }

    @Test func routingAcceptsInjectedMatcherOverDefaultHeuristic() {
        // 注入判定闭包：默认启发式只是兜底，组合根可换 EDID/IORegistry 精确判定
        #expect(DDCRouting.volumeRoute(
            defaultOutputModelUID: "厂商自命名外接屏",
            ddcAvailable: true,
            isExternalDisplay: { $0 == "厂商自命名外接屏" }
        ) == .ddc)
        // 注入后默认启发式不再兜底：含 "display" 但闭包不认 → 系统音量
        #expect(DDCRouting.volumeRoute(
            defaultOutputModelUID: "DisplayPort",
            ddcAvailable: true,
            isExternalDisplay: { _ in false }
        ) == .system)
    }

    @Test func defaultMatcherRecognizesDisplaySubstringCaseInsensitively() {
        #expect(DDCRouting.defaultExternalDisplayMatcher("DisplayPort"))
        #expect(DDCRouting.defaultExternalDisplayMatcher("apple display"))
        #expect(!DDCRouting.defaultExternalDisplayMatcher("MacBook Pro Speakers"))
        #expect(!DDCRouting.defaultExternalDisplayMatcher(""))
    }

    // MARK: - 客户端音量扩展（降级路径注入）

    @Test func nilSymbolsDegradeVolumeDomainSilently() {
        let client = DDCClient(symbols: nil)  // dlsym 失败的等价注入
        let display = DDCDisplay(id: 1)
        #expect(client.readVolume(of: display) == nil)
        #expect(!client.writeVolume(50, to: display))
    }

    @Test func failingI2CPipelineDegradesVolumeWithoutCrashing() {
        // create 成功但 I2C 全失败：两段式读值/写值管道走通也不崩（DDC-04 同源）
        let fake = IOAVServiceSymbols(
            create: { _ in OpaquePointer(bitPattern: 1) },
            readI2C: { _, _, _, _, _ in KERN_FAILURE },
            writeI2C: { _, _, _, _, _ in KERN_FAILURE },
            release: { _ in })
        let client = DDCClient(symbols: fake)
        let display = DDCDisplay(id: 0xDEAD)
        #expect(client.readVolume(of: display) == nil)
        #expect(!client.writeVolume(30, to: display))
        // 出口钳制对音量同样生效：越界值经 clampDDCValue 收敛后才进帧管道
        #expect(clampDDCValue(150) == 100)
        #expect(clampDDCValue(-7) == 0)
    }
}
