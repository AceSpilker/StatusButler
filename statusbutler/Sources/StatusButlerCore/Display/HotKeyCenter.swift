import Foundation
import Carbon.HIToolbox

// MARK: - 全局热键（T-051 · A11 E21 SCR-01 全局热键入口 / E22 最小 Carbon 包装）
// Carbon RegisterEventHotKey 是系统级全局热键仅存的公开稳定通道（NSEvent addGlobalMonitor
// 只能旁观不能拦截），现代 App（Raycast/Keyboard Maestro 系）同款路线。

/// 热键组合：Carbon 键码 + 修饰键位掩码。掩码编码是纯函数——UI 录制器只产 Bool，
/// 持久化/比较只看 UInt32，两侧不共享可变状态。
public struct HotKeyCombo: Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    /// Carbon 修饰键位组合（cmdKey/optionKey/shiftKey/controlKey 的 OR）
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 布尔组合 → Carbon 修饰键位掩码（纯函数）
    public static func encodeModifiers(
        command: Bool = false, option: Bool = false, shift: Bool = false, control: Bool = false
    ) -> UInt32 {
        (command ? UInt32(cmdKey) : 0)
            | (option ? UInt32(optionKey) : 0)
            | (shift ? UInt32(shiftKey) : 0)
            | (control ? UInt32(controlKey) : 0)
    }

    /// 布尔便捷构造（录制器直连）
    public init(
        keyCode: UInt32,
        command: Bool = false, option: Bool = false, shift: Bool = false, control: Bool = false
    ) {
        self.init(
            keyCode: keyCode,
            modifiers: Self.encodeModifiers(command: command, option: option, shift: shift, control: control))
    }
}

/// 注册中心：@MainActor 收敛全部可变状态；Carbon C 回调无法捕获上下文，
/// 派发路径 = 静态回调解析 EventHotKeyID → Task { @MainActor } 跳回主线程执行动作。
/// 回调本身命中在主事件循环，再经 Task 加一跳是隔离纪律所需（时序对单发用户热键无感）。
@MainActor
public final class HotKeyCenter {
    public typealias HotKeyAction = @MainActor () -> Void

    public static let shared = HotKeyCenter()

    /// 事件签名 fourcc 'SBHK'：回调侧校验事件归属本 App（防其他框架混注同类事件）
    private static let signature = OSType(0x5342_484B)
    private static let keyboardSpec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))

    /// 进程级唯一的 Carbon 键盘处理器盒（装一次进程共享）。static var 继承本类的
    /// @MainActor 隔离，只被下方 @MainActor 方法读写——无需 nonisolated(unsafe)。
    private static var handlerBox: HotKeyHandlerBox?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotKeyAction] = [:]

    public init() {}

    /// 已注册热键数（设置页/测试观察口）
    public var registeredCount: Int { hotKeyRefs.count }

    /// 注册全局热键；id 由调用方分配（如 SCR-01 熄屏键），同 id 重复注册拒绝（false）。
    /// - Returns: 注册成功与否；失败（系统拒绝/签名冲突）静默降级——热键属增益功能，
    ///   绝不因注册失败阻断 App。
    // TODO(T-051→E22 面板接线): 冲突占位——同一组合被本 App 多入口重复注册、
    // 或被其他 App 抢占（注册成功但永不回调）的检测与协商（冲突提示/可改键 UI）
    // 随设置页热键面板落地；当前策略：后注册的组合沿用先注册者的系统占用。
    @discardableResult
    public func register(id: UInt32, combo: HotKeyCombo, action: @escaping HotKeyAction) -> Bool {
        guard hotKeyRefs[id] == nil else { return false }
        installKeyboardHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        actions[id] = action
        return true
    }

    /// 注销；未注册的 id 静默成功（幂等）
    public func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    /// 注销全部（设置页整组停用/teardown）
    public func unregisterAll() {
        for id in hotKeyRefs.keys {
            unregister(id: id)
        }
    }

    // MARK: 内部

    private func fire(id: UInt32) {
        actions[id]?()
    }

    private func installKeyboardHandlerIfNeeded() {
        guard Self.handlerBox == nil else { return }
        let spec = Self.keyboardSpec
        // C 回调（无捕获）：只做参数解析与主线程派发，不触碰任何隔离状态
        let handler: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID)
            guard hotKeyID.signature == HotKeyCenter.signature else { return noErr }
            let id = hotKeyID.id
            Task { @MainActor in
                HotKeyCenter.shared.fire(id: id)
            }
            return noErr
        }
        let box = HotKeyHandlerBox()
        guard box.install(handler: handler, spec: spec) else { return }
        Self.handlerBox = box
    }
}

/// Carbon 事件处理器句柄盒：@unchecked Sendable 论证——handlerRef 只在 NSLock 内读写。
/// 进程级单例语义由 HotKeyCenter.handlerBox 持有，App 退出随进程回收
///（deinit 兜底 RemoveEventHandler，teardown 安全）。
private final class HotKeyHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handlerRef: EventHandlerRef?

    func install(handler: EventHandlerUPP, spec: EventTypeSpec) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard handlerRef == nil else { return true }  // 幂等：进程只装一次
        var spec = spec
        var ref: EventHandlerRef?
        guard InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &spec, nil, &ref
        ) == noErr, let ref else { return false }
        handlerRef = ref
        return true
    }

    deinit {
        // teardown：App 生命周期终点卸载处理器；进程直接终止时由系统回收
        if let ref = handlerRef {
            RemoveEventHandler(ref)
        }
    }
}
