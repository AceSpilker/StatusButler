import AppKit

// Dock 图标渲染（A2·S2）：同一场景状态，圆角底板 + 内缩三段；背景跟随外观
public enum DockIconRenderer {
    public static let pointSize: CGFloat = 128

    public static func image(
        scene: IconSceneState,
        pointSize: CGFloat = DockIconRenderer.pointSize,
        dark: Bool
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        let pixels = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        rep.size = NSSize(width: pointSize, height: pointSize)
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = nsContext
        if let ctx = nsContext?.cgContext {
            // 圆角底板
            let chip = CGRect(x: 8, y: 8, width: pointSize - 16, height: pointSize - 16)
            let chipColor: NSColor = dark
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : NSColor(calibratedWhite: 0.97, alpha: 1)
            ctx.setFillColor(chipColor.cgColor)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 28, cornerHeight: 28, transform: nil))
            ctx.fillPath()
            // 内缩绘制三段（同源复用；内缩后 120 几何缩放到 ~88pt）
            ctx.saveGState()
            let inner = chip.insetBy(dx: 10, dy: 10)
            let scale = min(inner.width, inner.height) / StatusIconRenderer.canvasSize
            ctx.translateBy(x: inner.minX, y: inner.minY)
            ctx.scaleBy(x: scale, y: scale)
            StatusIconRenderer.drawSegments(
                scene: scene,
                palette: .adaptive(dark: dark),
                in: ctx
            )
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }
}
