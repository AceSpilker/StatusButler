import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// T-208 / E7·TH-03~05：主题导入导出编排——文件面板 → 校验 → 差异预览 → 应用（跳过项可见）。
// 纯逻辑（差异表/校验分型/往返）与 AppKit 面板彻底分离：面板与文件 IO 经闭包注入，
// 测试注入假 pickURLs/read/write 即可全流程驱动；默认闭包才碰 NSOpenPanel/NSSavePanel
// （runModal 必须主线程，控制器 @MainActor 收敛，View 的按钮动作天然在主线程调用）。

// MARK: - 差异预览（纯函数）

/// 预览表一行：字段名 / 现值 / 新值。id 即字段名（同字段不重复出两行）
public struct ThemeDiffRow: Equatable, Identifiable, Sendable {
    public let field: String
    public let currentValue: String
    public let newValue: String

    public var id: String { field }

    public init(field: String, currentValue: String, newValue: String) {
        self.field = field
        self.currentValue = currentValue
        self.newValue = newValue
    }
}

/// 差异表构建：只列"新主题携带（非 nil）"的字段——nil = 主题不覆盖此项（TH-02 语义），
/// 没有差异就不出行（预览表是"将发生什么"的诚实清单，不是全字段清单）。
/// 行序固定（外观键 → 分区 → 槽位），测试与预览表展示共用同一确定性
public enum ThemeDiffer {
    public static func rows(current: ButlerTheme, incoming: ButlerTheme) -> [ThemeDiffRow] {
        var rows: [ThemeDiffRow] = []
        let appearance = incoming.appearance
        func append(_ field: String, _ current: String?, _ new: String) {
            rows.append(ThemeDiffRow(field: field, currentValue: current ?? "—", newValue: new))
        }

        if let iconSize = appearance?.iconSize {
            append("图标大小", current.appearance?.iconSize.map { "\(Int($0)) pt" }, "\(Int(iconSize)) pt")
        }
        if let symbolScale = appearance?.symbolScale {
            append("符号缩放（暂未支持）", current.appearance?.symbolScale.map { "\($0)" }, "\(symbolScale)")
        }
        if let ringStyle = appearance?.ringStyle {
            append("环形样式（暂未支持）", current.appearance?.ringStyle?.rawValue, ringStyle.rawValue)
        }
        if let threshold = appearance?.batteryThreshold {
            append("低电阈值（暂未支持）", current.appearance?.batteryThreshold.map { "\($0)%" }, "\(threshold)%")
        }
        if let hex = appearance?.accentHex {
            append("强调色（暂未支持）", current.appearance?.accentHex, hex)
        }
        if let hex = appearance?.warningHex {
            append("警示色（暂未支持）", current.appearance?.warningHex, hex)
        }
        if let hex = appearance?.chargingHex {
            append("充电色（暂未支持）", current.appearance?.chargingHex, hex)
        }
        if let shows = appearance?.showsBatteryPercentage {
            append("显示电池百分比", current.appearance?.showsBatteryPercentage.map(boolText), boolText(shows))
        }
        if let sections = incoming.sections {
            append("分区排序（应用时跳过）", current.sections.map { "\($0.count) 项" }, "\(sections.count) 项")
        }
        if let slotID = incoming.footerSlotID {
            append("底部槽位", current.footerSlotID.map(slotTitle), slotTitle(slotID))
        }
        return rows
    }

    private static func boolText(_ value: Bool) -> String { value ? "开" : "关" }

    /// 槽位 id → 展示名：注册表已知用中文名，未知回退 id（诚实，不猜）
    private static func slotTitle(_ id: String) -> String {
        SettingsSlotOptions.option(id: id)?.title ?? id
    }
}

// MARK: - 文件面板（AppKit 主线程；仅默认闭包触达，测试永不实例化）

@MainActor
public enum ThemeFilePanels {
    /// 导入选文件的扩展名过滤：.butler-theme 非系统类型，动态注册 UTType；
    /// 注册失败回退 .json（文件仍是 JSON，读取校验兜底）
    private static var themeType: UTType {
        UTType(filenameExtension: fileExtension) ?? .json
    }

    public static let fileExtension = "butler-theme"

    public static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [themeType]
        panel.message = "选择要导入的 .butler-theme 主题文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    public static func savePanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [themeType]
        panel.nameFieldStringValue = "主题.\(fileExtension)"
        panel.message = "导出当前外观配置为 .butler-theme 文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - 导入导出编排

/// 导入流程状态机：idle →（选文件+校验过）previewing →（确认）applied；
/// 任何一步失败进 failed（带可读理由）；用户取消文件面板回 idle（取消不是失败）
public enum ThemeImportPhase: Equatable, Sendable {
    case idle
    case previewing(rows: [ThemeDiffRow])
    case applied(skipped: [String])
    case failed(message: String)
}

/// 导出结果：面板取消不算失败（nil 状态复位）
public enum ThemeExportOutcome: Equatable, Sendable {
    case idle
    case saved(path: String)
    case failed(message: String)
}

@MainActor
public final class ThemePortController: ObservableObject {
    @Published public private(set) var importPhase: ThemeImportPhase = .idle
    @Published public private(set) var exportOutcome: ThemeExportOutcome = .idle
    /// 预览中的候选主题（confirmImport 的落库对象；failed/idle 时为 nil）
    private var pendingTheme: ButlerTheme?

    public typealias URLPicker = () -> URL?

    private let pickImportURL: URLPicker
    private let pickExportURL: URLPicker
    private let readData: (URL) throws -> Data
    private let writeData: (URL, Data) throws -> Void

    public init(
        pickImportURL: @escaping URLPicker = { ThemeFilePanels.openPanel() },
        pickExportURL: @escaping URLPicker = { ThemeFilePanels.savePanel() },
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) },
        writeData: @escaping (URL, Data) throws -> Void = { try $1.write(to: $0, options: .atomic) }
    ) {
        self.pickImportURL = pickImportURL
        self.pickExportURL = pickExportURL
        self.readData = readData
        self.writeData = writeData
    }

    // MARK: 导入

    /// 选文件 → 读 → 校验 → 差异表就绪。取消面板/读取失败/校验失败各自收敛为一种终态
    public func beginImport(from store: SettingsStore) {
        reset()
        guard let url = pickImportURL() else { return }  // 用户取消：保持 idle
        let data: Data
        do {
            data = try readData(url)
        } catch {
            importPhase = .failed(message: "无法读取文件：\n\(error.localizedDescription)")
            return
        }
        switch ThemeCodec.validate(data) {
        case .failure(let themeError):
            importPhase = .failed(message: themeError.description)
        case .success(let theme):
            pendingTheme = theme
            importPhase = .previewing(rows: ThemeDiffer.rows(current: ThemeApplier.snapshot(from: store), incoming: theme))
        }
    }

    /// 确认应用：ThemeApplier 落地并留跳过项说明（TH-05 可见，不静默吞）
    public func confirmImport(to store: SettingsStore) {
        guard let theme = pendingTheme else { return }
        let skipped = ThemeApplier.apply(theme, to: store)
        pendingTheme = nil
        importPhase = .applied(skipped: skipped)
    }

    /// 取消预览 / 关闭结果提示
    public func reset() {
        pendingTheme = nil
        importPhase = .idle
    }

    // MARK: 导出

    /// snapshot → 编码 → 落盘。字节稳定（sortedKeys），同配置两次导出文件可 diff 为空
    public func export(from store: SettingsStore) {
        exportOutcome = .idle
        guard let url = pickExportURL() else { return }  // 用户取消：保持 idle
        do {
            try writeData(url, ThemeCodec.encode(ThemeApplier.snapshot(from: store)))
            exportOutcome = .saved(path: url.path)
        } catch {
            exportOutcome = .failed(message: "导出失败：\n\(error.localizedDescription)")
        }
    }

    public func dismissExportNotice() {
        exportOutcome = .idle
    }
}
