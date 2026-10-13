import AppKit
import Carbon.HIToolbox
import SwiftUI

// T-206 / E22：热键设置页——录制 UI + 键位持久化 + 冲突检测（纯函数）。
// 边界（P1 分区纪律）：本页只读写 SettingsStore.hotKeyAssignments 并展示；
// 不在本页向 HotKeyCenter 注册全局热键——注册接线是组合根的活（见文件尾集成注记）。
// HotKeyCenter（Display/）只读消费：录制捕获复用其公开的 HotKeyCombo 布尔构造/encodeModifiers。

// MARK: - 动作集（E22 首批四项；熄屏 off? 按 C2 排期不含在本页——E21 复活决策未落）

/// 热键可绑动作。rawValue 对齐 ActionRegistry 的 action id——注册接线侧可零翻译路由到
/// AutomationCoordinator.performAction(ActionRegistry.action(id:))；本页不 import Actions 层
/// （依赖单向：Settings 只被 UI 消费，不反向触碰 Automation），id 字面量由测试钉死两侧一致
public enum HotKeyActionID: String, CaseIterable, Identifiable, Sendable {
    case panelToggle = "panel"
    case mute = "mute"
    case fanMax = "fan-max"
    case speedtest = "speedtest"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .panelToggle: "弹层开关"
        case .mute: "静音"
        case .fanMax: "风扇全速应急"
        case .speedtest: "网络测速"
        }
    }

    public var symbolName: String {
        switch self {
        case .panelToggle: "square.grid.2x2"
        case .mute: "speaker.slash.fill"
        case .fanMax: "wind"
        case .speedtest: "speedometer"
        }
    }

    public var hint: String {
        switch self {
        case .panelToggle: "呼出/收起状态弹层"
        case .mute: "切换系统静音"
        case .fanMax: "需已安装特权 Helper（授权后生效）"
        case .speedtest: "占位键位：测速页随 T-217 接入后生效"
        }
    }
}

// MARK: - 录制/展示/冲突（纯函数半场；NSEvent 只在 View 录制器里出现）

/// 录制捕获与展示的纯函数集合。
/// NSEvent 本体无法在测试里伪造——捕获逻辑收 NSEvent.ModifierFlags（普通 OptionSet 值，
/// 可直构）+ UInt16 键码，与事件源解耦
public enum HotKeyRecorder {
    /// NSEvent 修饰键 → Carbon 组合键位。
    /// 规则：必须含 ⌘/⌥/⌃ 至少其一——仅 ⇧+字母会被 Carbon 全局拦截吞掉正常大写输入，
    /// 拒之门外比注册后键盘"失灵"诚实；无修饰键同理拒绝
    public static func capture(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> HotKeyCombo? {
        let command = modifiers.contains(.command)
        let option = modifiers.contains(.option)
        let control = modifiers.contains(.control)
        guard command || option || control else { return nil }
        // 复用 HotKeyCombo 的布尔构造（内部走 encodeModifiers 位掩码编码），不另写第二份位运算
        return HotKeyCombo(
            keyCode: UInt32(keyCode),
            command: command,
            option: option,
            shift: modifiers.contains(.shift),
            control: control
        )
    }

    /// 组合键展示串：⌃⌥⇧⌘（macOS 系统偏好顺序）+ 键面。未识别键码回退键码数字（诚实优于空白）
    public static func displayString(for combo: HotKeyCombo) -> String {
        var text = ""
        // Carbon 位掩码逐一探针：不做掩码→NSEvent.Flags 反向转换（那是又一轮映射面）
        if combo.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if combo.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if combo.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if combo.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel(for: combo.keyCode)
    }

    /// F 键码表：Carbon 的 F1~F19 键码不连续（0x7A/0x78/0x63…），区间匹配会踩
    /// Range lowerBound>upperBound 陷阱，只能查表
    private static let fKeyLabels: [UInt32: String] = {
        let entries: [(code: Int, label: Int)] = [
            (kVK_F1, 1), (kVK_F2, 2), (kVK_F3, 3), (kVK_F4, 4), (kVK_F5, 5), (kVK_F6, 6),
            (kVK_F7, 7), (kVK_F8, 8), (kVK_F9, 9), (kVK_F10, 10), (kVK_F11, 11), (kVK_F12, 12),
            (kVK_F13, 13), (kVK_F14, 14), (kVK_F15, 15), (kVK_F16, 16), (kVK_F17, 17),
            (kVK_F18, 18), (kVK_F19, 19),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (UInt32($0.code), "F\($0.label)") })
    }()

    /// Carbon 键码 → 键面文案（字母/数字/常用功能键；未识别回退键码数字）
    static func keyLabel(for keyCode: UInt32) -> String {
        if let fKey = fKeyLabels[keyCode] { return fKey }
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "空格"
        case kVK_Return: return "↩"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ANSI_Keypad0...kVK_ANSI_Keypad9:
            return "小键盘\(Int(keyCode) - kVK_ANSI_Keypad0)"
        default:
            return "#\(keyCode)"
        }
    }
}

/// 冲突条目：同一组合被 ≥2 个动作绑定时产出；actionIDs 排序保证确定性
public struct HotKeyConflict: Equatable, Hashable, Sendable {
    public let combo: HotKeyCombo
    public let actionIDs: [String]

    public init(combo: HotKeyCombo, actionIDs: [String]) {
        self.combo = combo
        self.actionIDs = actionIDs
    }
}

/// 冲突检测纯函数：分组计数，重复组合（≥2 动作）按组合排序输出。
/// 只查"本 App 内"的键位互撞——与其它 App 抢占的组合 Carbon 注册会失败，属注册接线侧的事
public func findConflicts(_ assignments: [String: HotKeyCombo]) -> [HotKeyConflict] {
    var byCombo: [HotKeyCombo: [String]] = [:]
    for (actionID, combo) in assignments.sorted(by: { $0.key < $1.key }) {
        byCombo[combo, default: []].append(actionID)
    }
    return byCombo
        .filter { $0.value.count >= 2 }
        .map { HotKeyConflict(combo: $0.key, actionIDs: $0.value.sorted()) }
        .sorted { $0.combo.keyCode < $1.combo.keyCode }
}

// MARK: - 设置页

public struct HotKeyPane: View {
    @ObservedObject private var settings: SettingsStore
    /// 正在录制的动作（nil = 无录制会话）；每次录制装一个本地 NSEvent 监听
    @State private var recordingActionID: String?
    @State private var keyMonitor: Any?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                ForEach(HotKeyActionID.allCases) { action in
                    actionRow(action)
                }
            } header: {
                Text("全局热键")
            } footer: {
                if !conflicts.isEmpty {
                    // 冲突必须可见：静默注册会让后注册的组合覆盖先者（HotKeyCenter 同 id 拒绝、
                    // 同组合不拒绝），用户以为两个都生效
                    ForEach(conflicts, id: \.self) { conflict in
                        Text("⚠ 键位 \(HotKeyRecorder.displayString(for: conflict.combo)) 被 \(conflict.actionIDs.joined(separator: "、")) 重复绑定，仅最后一个生效")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private var conflicts: [HotKeyConflict] {
        findConflicts(settings.hotKeyAssignments)
    }

    @ViewBuilder
    private func actionRow(_ action: HotKeyActionID) -> some View {
        let assignment = settings.hotKeyAssignments[action.rawValue]
        PreferenceRow(action.title, subtitle: action.hint) {
            HStack(spacing: 8) {
                if let assignment {
                    Text(HotKeyRecorder.displayString(for: assignment))
                        .monospaced()
                        .frame(minWidth: 64, alignment: .center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary.opacity(0.5))
                        )
                    if conflicts.contains(where: { $0.combo == assignment }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("该键位与其他动作冲突")
                    }
                } else {
                    Text("未设置")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .center)
                }
                Button(recordingActionID == action.rawValue ? "按下组合键…" : "录制") {
                    toggleRecording(action)
                }
                if assignment != nil {
                    Button("清除") {
                        settings.hotKeyAssignments.removeValue(forKey: action.rawValue)
                    }
                }
            }
        }
    }

    // MARK: 录制会话（UI 胶水；键位→组合的判定全在 HotKeyRecorder.capture 纯函数）

    private func toggleRecording(_ action: HotKeyActionID) {
        if recordingActionID == action.rawValue {
            stopRecording()
        } else {
            stopRecording()
            recordingActionID = action.rawValue
            // 本地监听（设置窗为 key window 时收到）：录制是短会话焦点态，
            // 期间吞掉按键防止同时落到背后控件；Esc 取消、有效组合落库即收
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleRecordedEvent(event)
            }
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        recordingActionID = nil
    }

    /// 返回 nil = 吞掉该事件（录制会话不外漏按键）；返回原事件 = 继续等待
    @MainActor
    private func handleRecordedEvent(_ event: NSEvent) -> NSEvent? {
        guard let actionID = recordingActionID else { return event }
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }
        guard let combo = HotKeyRecorder.capture(modifiers: event.modifierFlags, keyCode: event.keyCode) else {
            return nil  // 修饰键不足（仅 ⇧/无修饰）：吞掉继续等，避免裸键漏进别的控件
        }
        settings.hotKeyAssignments[actionID] = combo
        stopRecording()
        return nil
    }
}

// 集成注记（T-206 注册接线 · 主线在组合根完成，本页不碰 HotKeyCenter）：
// AppEnvironment.live() 里订阅设置驱动注册——
//
//     var hotKeyBag: Set<AnyCancellable> = []
//     func syncHotKeys(_ assignments: [String: HotKeyCombo]) {
//         let center = HotKeyCenter.shared
//         center.unregisterAll()
//         for (index, pair) in HotKeyActionID.allCases.enumerated() {
//             guard let combo = assignments[pair.rawValue] else { continue }
//             let id = UInt32(index + 1)  // 0 是 EventHotKeyID 保留语义，从 1 起
//             center.register(id: id, combo: combo) {
//                 guard let action = ActionRegistry.action(id: pair.rawValue) else { return }
//                 _ = automation.performAction(action)  // AutomationCoordinator（App/ 已有）
//             }
//         }
//     }
//     settings.$hotKeyAssignments
//         .dropFirst()                      // 订阅即回放：初始装填由 start() 后显式调一次
//         .removeDuplicates()               // 能效铁律：订阅去重
//         .sink { syncHotKeys($0) }
//         .store(in: &hotKeyBag)
//
// 要点：变更重注册走 unregisterAll 整组换（HotKeyCenter 同 id 拒绝重复注册）；
// register 失败静默降级是 HotKeyCenter 既有策略（热键属增益功能）。
// 熄屏（E21）复活后如需热键，在 HotKeyActionID 追加 case 并复用同一注册通道。
