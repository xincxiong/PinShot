import CoreGraphics
import Foundation

/// 截图相关的坐标 / 像素换算。全部是纯函数，便于单元测试。
///
/// 坐标系约定：
/// - NSScreen.frame、NSWindow.frame、覆盖窗 bounds：全局/局部 Cocoa 坐标（原点左下，y 向上），单位 pt。
/// - CGImage：像素数据，原点左上，y 向下。
enum CaptureGeometry {

    // MARK: - 基础

    /// 与 bounds 求交；空交集返回 .zero
    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let r = rect.intersection(bounds)
        if r.isNull || r.isEmpty { return .zero }
        return r
    }

    /// 把「屏幕局部 Cocoa 坐标（pt，左下原点）」换算成「屏幕截图像素坐标（px，左上原点）」
    static func pixelRect(forSelection selection: CGRect, in snapshot: ScreenSnapshot) -> CGRect {
        let local = CGRect(origin: .zero, size: snapshot.frame.size)
        let clipped = clamp(selection, to: local)
        guard clipped.width >= 1, clipped.height >= 1 else { return .zero }

        let scale = snapshot.scale
        let x = clipped.minX * scale
        let y = (snapshot.frame.height - clipped.maxY) * scale
        var pixel = CGRect(
            x: x.rounded(.down),
            y: y.rounded(.down),
            width: (clipped.width * scale).rounded(.up),
            height: (clipped.height * scale).rounded(.up)
        )
        pixel = pixel.intersection(CGRect(origin: .zero, size: snapshot.pixelSize))
        if pixel.isNull || pixel.width < 1 || pixel.height < 1 { return .zero }
        return pixel
    }

    /// 屏幕局部选区 → 全局 Cocoa 坐标（用于贴图窗口定位）
    static func globalRect(forSelection selection: CGRect, in snapshot: ScreenSnapshot) -> CGRect {
        CGRect(
            x: snapshot.frame.minX + selection.minX,
            y: snapshot.frame.minY + selection.minY,
            width: selection.width,
            height: selection.height
        )
    }

    /// 从整屏冻结帧裁剪出选区，返回可直接贴图的图片
    static func pinImage(from snapshot: ScreenSnapshot, selection: CGRect) -> PinnedImage? {
        pinImage(from: snapshot, selection: selection, minPixelSize: 1)
    }

    /// minPixelSize：小于该像素尺寸视为无效选区（默认 1px，选区阈值由 overlay 负责）
    static func pinImage(from snapshot: ScreenSnapshot, selection: CGRect, minPixelSize: CGFloat) -> PinnedImage? {
        let pixel = pixelRect(forSelection: selection, in: snapshot)
        guard pixel.width >= minPixelSize, pixel.height >= minPixelSize else { return nil }
        guard let cropped = snapshot.image.cropping(to: pixel.integral) else { return nil }
        let pointSize = CGSize(
            width: CGFloat(cropped.width) / snapshot.scale,
            height: CGFloat(cropped.height) / snapshot.scale
        )
        return PinnedImage(cgImage: cropped, pointSize: pointSize)
    }

    // MARK: - 窗口 / 缩放

    /// 等比缩放：把 imageSize 塞进 bounds 内（居中交给调用方）
    static func aspectFitSize(_ imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
    }

    /// 按固定宽高比缩放，返回新的尺寸；限制最小尺寸
    static func resizedSize(from size: CGSize, to target: CGSize, minSize: CGSize = PinShotConstants.minPinSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return minSize }
        let ratio = size.width / size.height
        var width = max(target.width, minSize.width)
        var height = width / ratio
        if height < minSize.height {
            height = minSize.height
            width = height * ratio
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// 把窗口 frame 约束在可视屏幕范围内（至少保留一部分窗口可见）
    static func clampedWindowFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var f = frame
        let minVisible: CGFloat = 40
        if f.maxX < visibleFrame.minX + minVisible { f.origin.x = visibleFrame.minX + minVisible - f.width }
        if f.minX > visibleFrame.maxX - minVisible { f.origin.x = visibleFrame.maxX - minVisible }
        if f.maxY < visibleFrame.minY + minVisible { f.origin.y = visibleFrame.minY + minVisible - f.height }
        if f.minY > visibleFrame.maxY - minVisible { f.origin.y = visibleFrame.maxY - minVisible }
        return f
    }

    /// 窗口是否与屏幕相交
    static func intersectsScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(frame) }
    }
}
