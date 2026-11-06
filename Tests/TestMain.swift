import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

// MARK: - 迷你测试框架

var testCount = 0
var failureCount = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    testCount += 1
    if condition {
        print("  ✅ \(name)")
    } else {
        failureCount += 1
        print("  ❌ \(name) \(detail())")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    check(actual == expected, name, "expected=\(expected) actual=\(actual)")
}

func checkClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.001) {
    check(abs(actual - expected) <= tolerance, name, "expected=\(expected) actual=\(actual)")
}

// MARK: - 测试工具

func makeImage(width: Int, height: Int, color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func makeSnapshot(
    frame: CGRect,
    scale: CGFloat,
    imageSize: CGSize
) -> ScreenSnapshot {
    let image = makeImage(width: Int(imageSize.width), height: Int(imageSize.height))
    return ScreenSnapshot(displayID: 1, frame: frame, scale: scale, image: image)
}

@main
enum PinShotTests {
    static func main() {
    // MARK: - 测试：坐标换算

    print("\n📍 CaptureGeometry")

    do {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2,
            imageSize: CGSize(width: 2880, height: 1800)
        )
        let selection = CGRect(x: 10, y: 20, width: 100, height: 50)
        let pixel = CaptureGeometry.pixelRect(forSelection: selection, in: snapshot)
        checkEqual(pixel, CGRect(x: 20, y: 1660, width: 200, height: 100), "主屏 Retina：点 → 像素（含 y 翻转）")
    }

    do {
        // 副屏在主屏左侧：全局 x 为负
        let snapshot = makeSnapshot(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            scale: 1,
            imageSize: CGSize(width: 1920, height: 1080)
        )
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        let pixel = CaptureGeometry.pixelRect(forSelection: selection, in: snapshot)
        checkEqual(pixel, CGRect(x: 100, y: 880, width: 200, height: 100), "副屏负坐标：点 → 像素")
        let global = CaptureGeometry.globalRect(forSelection: selection, in: snapshot)
        checkEqual(global, CGRect(x: -1820, y: 100, width: 200, height: 100), "副屏负坐标：屏幕局部 → 全局")
    }

    do {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1,
            imageSize: CGSize(width: 100, height: 100)
        )
        let clamped = CaptureGeometry.pixelRect(forSelection: CGRect(x: -20, y: -20, width: 50, height: 50), in: snapshot)
        checkEqual(clamped, CGRect(x: 0, y: 70, width: 30, height: 30), "越界选区被裁剪到屏幕内")

        let empty = CaptureGeometry.pixelRect(forSelection: CGRect(x: 200, y: 200, width: 10, height: 10), in: snapshot)
        check(empty == .zero, "完全越界选区返回 .zero")
    }

    do {
        // 非整数倍缩放
        let snapshot = makeSnapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1.5,
            imageSize: CGSize(width: 150, height: 150)
        )
        let pixel = CaptureGeometry.pixelRect(forSelection: CGRect(x: 10, y: 10, width: 21, height: 21), in: snapshot)
        checkEqual(pixel, CGRect(x: 15, y: 103, width: 32, height: 32), "1.5x 缩放四舍五入")
    }

    // MARK: - 测试：裁剪成贴图

    do {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            scale: 2,
            imageSize: CGSize(width: 100, height: 100)
        )
        let image = CaptureGeometry.pinImage(from: snapshot, selection: CGRect(x: 5, y: 5, width: 10, height: 10))
        check(image != nil, "合法选区能裁剪出图片")
        if let image {
            checkEqual(image.pixelSize, CGSize(width: 20, height: 20), "贴图像素尺寸 = 点 × scale")
            checkClose(image.pointSize.width, 10, "贴图点尺寸还原")
            checkClose(image.pointSize.height, 10, "贴图点尺寸还原（高）")
        }

        let tooSmall = CaptureGeometry.pinImage(
            from: snapshot,
            selection: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
            minPixelSize: 2
        )
        check(tooSmall == nil, "过小选区返回 nil")
    }

    do {
        checkEqual(
            CaptureGeometry.aspectFitSize(CGSize(width: 100, height: 50), in: CGSize(width: 300, height: 300)),
            CGSize(width: 300, height: 150),
            "等比适配：宽受限"
        )
        checkEqual(
            CaptureGeometry.aspectFitSize(CGSize(width: 50, height: 100), in: CGSize(width: 300, height: 300)),
            CGSize(width: 150, height: 300),
            "等比适配：高受限"
        )
    }

    do {
        let resized = CaptureGeometry.resizedSize(
            from: CGSize(width: 200, height: 100),
            to: CGSize(width: 50, height: 10),
            minSize: CGSize(width: 40, height: 40)
        )
        checkEqual(resized, CGSize(width: 80, height: 40), "等比缩放保持宽高比并遵守最小尺寸")
    }

    do {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let outOfBounds = CGRect(x: 1300, y: 800, width: 300, height: 200)
        let clamped = CaptureGeometry.clampedWindowFrame(outOfBounds, visibleFrame: visible)
        check(clamped.intersects(visible), "越界窗口会被拉回屏幕")
    }

    // MARK: - 测试：快捷键

    print("\n⌨️  HotKey")

    do {
        checkEqual(HotKeyCombo.defaultCapturePin.display, "⇧⌘2", "默认截图快捷键展示为 ⇧⌘2")
        checkEqual(HotKeyCombo.defaultCaptureCopy.display, "⇧⌘1", "默认复制快捷键展示为 ⇧⌘1")
        checkEqual(
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)).display,
            "⌃⌥⇧⌘P",
            "修饰键展示顺序"
        )
        checkEqual(KeyCodeNames.name(for: UInt32(kVK_Return)), "↩", "回车键展示名")
        checkEqual(KeyCodeNames.name(for: UInt32(kVK_LeftArrow)), "←", "方向键展示名")
    }

    // MARK: - 汇总

    print("\n\(failureCount == 0 ? "✅" : "❌") \(testCount - failureCount)/\(testCount) 个测试通过\n")
    exit(failureCount == 0 ? 0 : 1)
    }
}
