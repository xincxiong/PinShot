import AppKit
import CoreGraphics

/// 一张屏幕的冻结帧：原生像素图 + 该屏在全局 Cocoa 坐标中的位置。
struct ScreenSnapshot {
    let displayID: CGDirectDisplayID
    /// 全局 Cocoa 坐标（原点在左下，y 向上），对应 NSScreen.frame
    let frame: CGRect
    /// 屏幕 backing scale（Retina 为 2.0）
    let scale: CGFloat
    /// 原生分辨率的屏幕截图（左上原点像素数据）
    let image: CGImage

    var pointSize: CGSize { frame.size }
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    init(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat, image: CGImage) {
        self.displayID = displayID
        self.frame = frame
        self.scale = scale
        self.image = image
    }
}

/// 已裁剪好、准备贴到屏幕上的图片。pointSize 决定挂件窗口的初始尺寸。
struct PinnedImage {
    let cgImage: CGImage
    let pointSize: CGSize

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    var nsImage: NSImage {
        let img = NSImage(cgImage: cgImage, size: pointSize)
        return img
    }

    init(cgImage: CGImage, pointSize: CGSize) {
        self.cgImage = cgImage
        self.pointSize = pointSize
    }
}

/// 贴图的放置模式
enum PinPlacement: String, Codable {
    /// 浮在所有窗口最上层（原有行为）
    case floating
    /// 挂在桌面：位于桌面图标之上、普通窗口之下，像桌面便签
    case desktop
}

enum PinShotConstants {
    static let appName = "PinShot"
    static let bundleIdentifier = "com.kuxin.pinshot"
    static let version = "1.1.0"

    /// 贴图最小尺寸（pt）
    static let minPinSize = CGSize(width: 40, height: 40)
    /// 贴图圆角（pt）
    static let pinCornerRadius: CGFloat = 8
    /// 贴图边框宽度（pt）
    static let pinBorderWidth: CGFloat = 1
    /// 右下角缩放热区（pt）
    static let resizeHandleSize: CGFloat = 16
    /// 截图前隐藏已有贴图后等待的时间（秒），确保合成器已更新
    static let hideBeforeCaptureDelay: TimeInterval = 0.12
    static let pinAnimationDuration: TimeInterval = 0.18
    static let autoHidePollInterval: TimeInterval = 0.2

    /// 贴图窗口层级：高于普通浮动窗口，低于系统弹窗；配合 fullScreenAuxiliary 可浮在全屏应用上
    static let pinWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

    /// 桌面模式层级：在桌面图标之上、普通窗口之下
    static let desktopPinWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
}
