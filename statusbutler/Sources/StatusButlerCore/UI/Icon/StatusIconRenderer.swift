import AppKit

// 三合一图标渲染器（A2·S1 / B1 图标管线）：
// 120×120 原始几何坐标系，按目标 pt 等比缩放；上电池 / 中信号弧 / 下音量点
public enum StatusIconRenderer {
    public static let canvasSize: CGFloat = 120

    struct Palette {
        let ink: NSColor        // 主线条
        let accent: NSColor     // 充电绿
        let lowBattery: NSColor // 低电红
        static func adaptive(dark: Bool) -> Palette {
            Palette(
                ink: dark ? .white : .black,
                accent: NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.29, alpha: 1),
                lowBattery: NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.20, alpha: 1)
            )
        }
    }

    /// 渲染菜单栏图标（pt 尺寸；显式 2x 位图，headless 环境确定性输出）
    public static func image(scene: IconSceneState, pointSize: CGFloat, dark: Bool) -> NSImage {
        let palette = Palette.adaptive(dark: dark)
        let scale = pointSize / canvasSize
        let pixelsPerPoint: CGFloat = 2
        let pixels = Int(pointSize * pixelsPerPoint)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
        rep.size = NSSize(width: pointSize, height: pointSize)

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = nsContext
        if let ctx = nsContext?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            drawBattery(scene: scene, palette: palette, in: ctx)
            drawSignal(scene: scene, palette: palette, in: ctx)
            drawVolume(scene: scene, palette: palette, in: ctx)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    // MARK: - 顶部：电池（胶囊 + 电量填充 + 充电闪电）

    private static func drawBattery(scene: IconSceneState, palette: Palette, in ctx: CGContext) {
        let body = CGRect(x: 30, y: 88, width: 52, height: 20)
        let stroke = strokeColor(scene: scene, palette: palette)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(3)
        // 胶囊外壳
        let bodyPath = CGPath(
            roundedRect: body, cornerWidth: 6, cornerHeight: 6, transform: nil
        )
        ctx.addPath(bodyPath)
        ctx.strokePath()
        // 正极凸头
        ctx.stroke(CGRect(x: body.maxX + 3, y: body.midY - 4, width: 4, height: 8))
        // 电量填充
        if let level = scene.batteryLevel {
            let fill = fillColor(level: level, palette: palette)
            let inner = body.insetBy(dx: 4, dy: 4)
            let width = inner.width * CGFloat(level) / 100.0
            if width > 0 {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: width, height: inner.height))
            }
        }
        // 充电：中心叠一枚闪电符号（SF Symbols）
        if scene.isCharging {
            drawSymbol("bolt.fill", in: CGRect(x: 48, y: 84, width: 16, height: 26),
                       color: palette.accent, ctx: ctx)
        }
    }

    // MARK: - 中部：Wi-Fi 信号弧（三段同心弧 + 底点）

    private static func drawSignal(scene: IconSceneState, palette: Palette, in ctx: CGContext) {
        let center = CGPoint(x: 60, y: 40)
        let color = scene.signalBars == 0 ? palette.ink.withAlphaComponent(0.3) : palette.ink
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        let arcs: [(radius: CGFloat, start: CGFloat, end: CGFloat)] = [
            (10, .pi * 0.25, .pi * 0.75),
            (20, .pi * 0.3, .pi * 0.7),
            (30, .pi * 0.36, .pi * 0.64),
        ]
        for (index, arc) in arcs.enumerated() {
            let active = scene.signalBars >= (index + 2)  // 点=1格，三弧=2/3/4格
            ctx.setStrokeColor((active ? palette.ink : palette.ink.withAlphaComponent(0.25)).cgColor)
            ctx.addArc(
                center: CGPoint(x: center.x, y: center.y + 4),
                radius: arc.radius,
                startAngle: arc.start,
                endAngle: arc.end,
                clockwise: false
            )
            ctx.strokePath()
        }
        // 底点（1 格）
        let dotActive = scene.signalBars >= 1
        ctx.setFillColor((dotActive ? palette.ink : palette.ink.withAlphaComponent(0.25)).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
    }

    // MARK: - 底部：音量点（0–4）

    private static func drawVolume(scene: IconSceneState, palette: Palette, in ctx: CGContext) {
        let dotSize: CGFloat = 9
        let gap: CGFloat = 7
        let total = CGFloat(4) * dotSize + CGFloat(3) * gap
        var x = (canvasSize - total) / 2
        for index in 0..<4 {
            let active = scene.volumeDots >= (index + 1)
            let color = scene.isMuted
                ? palette.lowBattery.withAlphaComponent(0.6)
                : (active ? palette.ink : palette.ink.withAlphaComponent(0.22))
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: 8, width: dotSize, height: dotSize))
            x += dotSize + gap
        }
    }

    // MARK: - 辅助

    private static func strokeColor(scene: IconSceneState, palette: Palette) -> NSColor {
        if let level = scene.batteryLevel, level <= 20, !scene.isCharging {
            return palette.lowBattery
        }
        return palette.ink
    }

    private static func fillColor(level: Int, palette: Palette) -> NSColor {
        if level <= 20 { return palette.lowBattery }
        return palette.accent
    }

    private static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, ctx: CGContext) {
        guard let base = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        ) else { return }
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: rect.size))
        color.set()
        NSRect(origin: .zero, size: rect.size).fill(
            using: .sourceAtop
        )
        tinted.unlockFocus()
        tinted.draw(in: rect)
    }
}
