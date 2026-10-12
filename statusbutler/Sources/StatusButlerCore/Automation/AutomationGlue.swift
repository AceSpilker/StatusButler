import Foundation

// T-052: 执行器绑定构建器（A9·AC-05）。把"动作注册表"翻译成"可注入闭包表"的纯函数半场：
// 真实系统操作（音量/弹层/风扇/槽位/主题/熄屏/蓝牙）全部由集成方通过 AutomationStore 注入，
// 本文件零系统调用（AU-04：自动化层不存在任意执行面）；未接线动作一律诚实拒绝（AC-02），绝不伪装成功。
// 不 import 任何控制器——Automation 是旁路消费者，依赖单向铁律禁止它反向触碰 UI 层。

/// 宽接口占位（T-052 集成半场替换/扩充真实形态）：主 App 组合根聚合的"可接线系统"门面。
/// 协议方法只收发 ActionOutcome——可用性/权限/降级的裁决权留在实现侧（引擎不替执行器做决定）；
/// 不预设隔离域：真实实现自行处理线程/主线程桥接，协议形状保持同步纯调用以便测试注入假实现。
public protocol AutomationStore: Sendable {
    /// 音量设定（0...100）——volume 动作的真实落点示例（集成时接 CoreAudio/AppleScript set volume）
    func setVolume(level: Int) -> ActionOutcome
    /// 静音切换——mute 动作的真实落点示例
    func toggleMute() -> ActionOutcome
}

/// 执行器绑定构建器
public enum AutomationGlue {
    /// 动作绑定：注册表 id 寻址的执行闭包。@Sendable 以便直接喂 ActionCenter 的 ActionExecutor
    public typealias ActionBinding = @Sendable (ButlerCommand) -> ActionOutcome

    /// 纯构建：注册表 id → 执行闭包。键域结构性全覆盖 ActionRegistry.builtin
    /// （未手写绑定的 id 由尾部循环兜底占位），测试钉死两侧恒等——AC-05：面板/URL/CLI 一套动作表喂三处。
    ///
    /// 集成方接 ActionCenter 的姿势：
    ///
    ///     let bindings = AutomationGlue.executorBindings(store: realStore)
    ///     let center = ActionCenter(executor: { action, command in
    ///         bindings[action.id]?(command) ?? .rejected(reason: "动作未注册：\(action.id)")
    ///     })
    public static func executorBindings(store: some AutomationStore) -> [String: ActionBinding] {
        var bindings: [String: ActionBinding] = [:]

        // ── 示例实现：音量域（唯一给出真实接线形状的动作，其余为骨架）──
        bindings["volume"] = { command in
            switch command.verb {
            case "volume/set":
                // parse 已保证 0...100 整数；Int 失败兜底拒绝（防直构命令绕过解析——同 resolve 的纵深防御）
                guard let level = Int(command.args["value"] ?? "") else {
                    return .rejected(
                        reason: CommandError.invalidValue(parameter: "value", value: command.args["value"] ?? "").summary
                    )
                }
                return store.setVolume(level: level)
            case "volume/up", "volume/down":
                // TODO(T-052 集成半场): 步进需要"当前音量"读通道（VolumeMonitor 采样值或 CoreAudio 查询），
                // AutomationStore 扩充 stepVolume(_ delta: Int) 后在此接线
                return .rejected(reason: "音量步进待接线：\(command.verb) 需当前音量读通道（T-052 集成半场）")
            default:
                return .rejected(reason: "volume 动词不匹配：\(command.verb)")
            }
        }
        bindings["mute"] = { _ in store.toggleMute() }

        // status 是只读查询：不经执行器（CLIEngine 走快照通道直读，AU-04 查询零副作用）；
        // URL 通道没有输出面，同样拒绝并指路——诚实分级优于伪装成功
        bindings["status"] = { _ in
            .rejected(reason: "status 为只读查询：CLI 用 statusbutler status [--json]（快照通道直读），URL 通道无输出面")
        }

        // TODO(T-052 集成半场): 其余域接线位置——
        //   panel             → StatusPopoverController（show / 直达 thermal/battery/network 分区）
        //   fan-max           → FanControlEngine + 特权 Helper（先复核 needsPermission("特权 Helper")，A5·TF-30）
        //   slot-cycle        → SlotSystem 槽位轮换
        //   theme             → ThemeApplier / ThemePresets
        //   screen-off        → 熄屏通道（A11·E21 断言守护模式）
        //   bluetooth-connect → IOBluetooth 设备连接（device 参数已百分号解码）
        //   wifi-toggle / bluetooth-toggle / darkmode / dnd / speedtest / healthcheck → 面板侧动作逐步补

        // ── 骨架兜底：注册表内所有未手写绑定的动作占位（诚实拒绝，AC-02）──
        for action in ActionRegistry.builtin where bindings[action.id] == nil {
            bindings[action.id] = { command in
                .rejected(reason: unwiredReason(for: action, command: command))
            }
        }
        return bindings
    }

    /// 未接线动作的拒绝理由：按注册表 availability 分级翻译（诚实分级的关键在"拒绝时说清为什么"）
    static func unwiredReason(for action: ButlerAction, command: ButlerCommand) -> String {
        switch action.availability {
        case .available:
            return "动作未接线：\(action.id)（真实系统操作由集成方注入，T-052 集成半场）"
        case .needsPermission(let permission):
            return "动作未接线且需授权（\(permission)）：\(action.id)（集成方注入后启用）"
        case .deepLinkOnly:
            return "该动作只提供系统设置深链，不开放命令执行：\(action.id)"
        case .unavailableOnSystem:
            return "当前系统不支持：\(action.id)"
        }
    }
}
