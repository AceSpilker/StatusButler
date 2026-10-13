import Foundation

// MARK: - 趣味动画皮肤（T-220 · E24：CPU 负载驱动的小动画槽位皮肤）
//
// 引擎+模型+测试完整；渲染端接线留注记——菜单栏图标重绘由充电时钟（ChargingEffectClock）
// 的节拍驱动，皮肤帧率挂同一时钟（见 StatusIconRenderer.drawSlotText 的 TODO）。
// 本文件只做帧表与取帧纯函数：定时器、CPU 负载映射、重绘触发全部归接线层。

/// 一组动画皮肤帧：SF Symbol 名序列 + 播放帧率。
/// fps 在构造口钳制（1...12）：0/负值无意义，>12 菜单栏肉眼不可分辨还白白重绘（能效铁律）。
public struct SkinFrame: Equatable, Sendable {
    public static let fpsRange: ClosedRange<Int> = 1...12

    /// 皮肤代表符号（设置项展示与非动画回退帧；不参与帧序列循环）
    public let symbol: String
    /// 帧序列（环形循环，元素为 SF Symbol 名）；空串帧在构造口剔除
    public let frames: [String]
    public let fps: Int

    public init(symbol: String, frames: [String], fps: Int) {
        self.symbol = symbol
        // 帧表完整性出口：剔空串后为空（全脏输入）退化为单帧 [symbol]，永不产出空表——
        // 空表会让取帧越界防御成为常态而非异常
        let cleaned = frames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.frames = cleaned.isEmpty ? [symbol] : cleaned
        self.fps = min(max(fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound)
    }

    /// 环形取帧（纯函数）：按经过时间 × fps 的整步数取模。
    /// 负时间输入按 0 处理（时钟回拨不越界）
    public func frame(at elapsed: TimeInterval) -> String {
        let step = max(elapsed, 0) * Double(fps)
        let index = Int(step) % frames.count
        return frames[index]
    }
}

/// 内置皮肤帧表（E24：默认关、随主题分发——皮肤 id 进主题文件属后续主题 schema 事项）
public enum AnimatedSkinCatalog {
    public static let runningCatID = "runningCat"
    public static let swimmingFishID = "swimmingFish"

    /// 跑猫：4 帧 cat/cat.fill 交替（填充态闪动近似奔跑节奏）
    public static let runningCat = SkinFrame(
        symbol: "cat.fill",
        frames: ["cat.fill", "cat", "cat.fill", "cat"],
        fps: 6
    )

    /// 游鱼：3 帧 fish 变体（fill 回弹近似摆尾）
    public static let swimmingFish = SkinFrame(
        symbol: "fish.fill",
        frames: ["fish.fill", "fish", "fish.fill"],
        fps: 4
    )

    public static let all: [String: SkinFrame] = [
        runningCatID: runningCat,
        swimmingFishID: swimmingFish,
    ]

    /// id → 皮肤。nil（含设置未配置/非法 id）= 不启用——查表失败静默关，
    /// 与昼夜主题"预设查不到即不切换"同一兜底口径
    public static func skin(named id: String?) -> SkinFrame? {
        id.flatMap { all[$0] }
    }
}
