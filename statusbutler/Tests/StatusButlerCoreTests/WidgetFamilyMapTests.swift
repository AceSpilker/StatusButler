import Foundation
import Testing
@testable import StatusButlerCore

// T-054b: 族注册纯表——六族全覆盖非空、深链必须落在 butler:// 命令白名单内（AU-01 联动）。
// 视图工厂段不可单测（canImport WidgetKit 的 SwiftUI 视图），注册表的其余一切在此钉死

@Suite struct WidgetFamilyMapTests {

    @Test func registryCoversAllSixKindsWithNoEmptyFields() {
        let all = WidgetFamilyMap.all
        #expect(all.count == 6)
        // 顺序即组件库展示顺序，与 ButlerWidgetKind 声明序一致
        #expect(all.map(\.kind) == ButlerWidgetKind.allCases)
        #expect(ButlerWidgetKind.allCases.map(\.rawValue) == [
            "overview", "thermal", "fan", "performance", "calendar", "weather",
        ])
        for descriptor in all {
            #expect(!descriptor.displayName.isEmpty)
            #expect(!descriptor.subtitle.isEmpty)
            #expect(!descriptor.deepLink.isEmpty)
            #expect(!descriptor.sizes.isEmpty)
            #expect(!descriptor.modelName.isEmpty)
            // 每族必须挂上一个显示模型——加族忘配模型在此爆红
            #expect(descriptor.modelName.hasSuffix("CardModel"))
        }
    }

    @Test func descriptorLookupMatchesRegistryForEveryKind() {
        for kind in ButlerWidgetKind.allCases {
            #expect(WidgetFamilyMap.descriptor(for: kind).kind == kind)
        }
        // 自检：查表结果与全表逐项一致（唯一构造源不该有二份真相）
        #expect(WidgetFamilyMap.allCasesDescriptorsEqual())
    }

    @Test func deepLinksAllLandOnCommandWhitelist() {
        for descriptor in WidgetFamilyMap.all {
            // widgetURL 深链最终进 ButlerCommand.parse——不在白名单的动词会被静默拒掉，
            // 组件点了没反应；注册表阶段就钉住，不留到扩展 target 才发现
            #expect(descriptor.deepLink.hasPrefix("butler://panel/"))
            let verb = String(descriptor.deepLink.dropFirst("butler://".count))
            #expect(ButlerCommand.allowed.contains(verb), "深链 \(verb) 不在命令白名单")
        }
        // thermal/fan 落温控面板；其余（面板动词未上白名单前）落总面板兜底
        #expect(WidgetFamilyMap.descriptor(for: .thermal).deepLink == "butler://panel/thermal")
        #expect(WidgetFamilyMap.descriptor(for: .fan).deepLink == "butler://panel/thermal")
        #expect(WidgetFamilyMap.descriptor(for: .overview).deepLink == "butler://panel/show")
    }

    @Test func sizesDeclaresOnlyAdaptedFamilies() {
        // 本版视图按 S/M 自适应设计（thermal/performance 预留 L），注册表尺寸与之一致
        #expect(WidgetFamilyMap.descriptor(for: .fan).sizes == "S")
        #expect(WidgetFamilyMap.descriptor(for: .overview).sizes == "S/M")
        #expect(WidgetFamilyMap.descriptor(for: .weather).sizes == "S/M")
        #expect(WidgetFamilyMap.descriptor(for: .performance).sizes == "S/M/L")
        for descriptor in WidgetFamilyMap.all {
            #expect(descriptor.sizes.hasPrefix("S"))  // 六族都至少有小尺寸
        }
    }
}

extension WidgetFamilyMap {
    /// 测试自检 helper：全表与逐 kind 查表互证
    static func allCasesDescriptorsEqual() -> Bool {
        ButlerWidgetKind.allCases.map { descriptor(for: $0) } == WidgetFamilyMap.all
    }
}
