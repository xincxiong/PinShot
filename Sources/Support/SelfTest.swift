import AppKit
import CoreGraphics

/// 离屏渲染自检（开发用）：在没有屏幕录制权限的环境下验证「选区遮罩」与「挂件外观」。
/// 用法：PinShot --render-test build/render
@MainActor
enum RenderSelfTest {

    static func run(outputDirectory: String) -> Bool {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("❌ 无法创建输出目录 \(directory.path): \(error)")
            return false
        }

        var allOK = true
        var outputs: [URL] = []

        // 1. 选区覆盖层：合成桌面 + 已框选状态
        let snapshot = makeDesktopSnapshot(pointSize: CGSize(width: 1000, height: 640), scale: 2)
        let selectionView = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: snapshot.pointSize),
            snapshot: snapshot
        )
        selectionView.selectionRect = CGRect(x: 232, y: 196, width: 392, height: 248)
        selectionView.showsSizeBadge = true
        let selectionURL = directory.appendingPathComponent("selection-overlay.png")
        if render(view: selectionView, to: selectionURL) {
            outputs.append(selectionURL)
        } else {
            allOK = false
            print("❌ 选区覆盖层渲染失败")
        }

        // 2. 挂件窗口：在合成桌面上截一块，带工具栏悬浮状态
        if let clipped = CaptureGeometry.pinImage(
            from: snapshot,
            selection: CGRect(x: 232, y: 196, width: 392, height: 248)
        ) {
            let pin = PinWindowController(
                image: clipped,
                frame: CGRect(x: 0, y: 0, width: clipped.pointSize.width, height: clipped.pointSize.height),
                renderOnly: true
            )
            let pinURL = directory.appendingPathComponent("pin-window.png")
            if pin.renderDebugPNG(to: pinURL) {
                outputs.append(pinURL)
            } else {
                allOK = false
                print("❌ 挂件窗口渲染失败")
            }
        } else {
            allOK = false
            print("❌ 合成截图裁剪失败")
        }

        print("\n\(allOK ? "✅" : "❌") 离屏渲染自检\(allOK ? "完成" : "失败")，产物：")
        for url in outputs {
            print("   \(url.path)")
        }
        return allOK
    }

    // MARK: - 渲染工具

    private static func render(view: NSView, to url: URL) -> Bool {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.orderFrontRegardless()
        window.displayIfNeeded()

        defer { window.orderOut(nil) }

        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            print("   渲染 \(url.lastPathComponent) \(rep.pixelsWide)×\(rep.pixelsHigh)")
            return true
        } catch {
            return false
        }
    }

    // MARK: - 合成"桌面"

    static func makeDesktopSnapshot(pointSize: CGSize, scale: CGFloat) -> ScreenSnapshot {
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            fatalError("无法创建离屏 bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.scaleBy(x: scale, y: scale)

        let bounds = CGRect(origin: .zero, size: pointSize)

        // 壁纸渐变
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.28, alpha: 1),
            NSColor(calibratedRed: 0.23, green: 0.32, blue: 0.55, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.68, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: -55)

        // 光斑
        for (index, center) in [
            CGPoint(x: 180, y: 520), CGPoint(x: 760, y: 180), CGPoint(x: 880, y: 600)
        ].enumerated() {
            let radius: CGFloat = index == 1 ? 180 : 120
            let circle = NSBezierPath(ovalIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            NSColor.white.withAlphaComponent(index == 1 ? 0.10 : 0.06).setFill()
            circle.fill()
        }

        // 模拟两个窗口
        drawFakeWindow(
            rect: CGRect(x: 60, y: 268, width: 500, height: 300),
            title: "Design.md — PinShot",
            bodyLines: 6,
            accent: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.25, alpha: 1)
        )
        drawFakeWindow(
            rect: CGRect(x: 590, y: 120, width: 340, height: 250),
            title: "Terminal",
            bodyLines: 5,
            accent: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
        )

        // 菜单栏
        NSColor.black.withAlphaComponent(0.38).setFill()
        CGRect(x: 0, y: pointSize.height - 24, width: pointSize.width, height: 24).fill()
        drawText("PinShot", at: CGPoint(x: 14, y: pointSize.height - 19), size: 11, color: .white)
        drawText("Fri 17:42", at: CGPoint(x: pointSize.width - 92, y: pointSize.height - 19), size: 11, color: .white.withAlphaComponent(0.9))

        // 桌面角落提示
        drawText("PinShot render self-test", at: CGPoint(x: 24, y: 24), size: 12, color: .white.withAlphaComponent(0.35))

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else { fatalError("无法生成 CGImage") }
        return ScreenSnapshot(
            displayID: 1,
            frame: CGRect(origin: .zero, size: pointSize),
            scale: scale,
            image: cgImage
        )
    }

    private static func drawFakeWindow(rect: CGRect, title: String, bodyLines: Int, accent: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.09, alpha: 0.92).setFill()
        path.fill()

        // 标题栏
        let titleBar = CGRect(x: rect.minX, y: rect.maxY - 34, width: rect.width, height: 34)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: titleBar, xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        CGRect(x: titleBar.minX, y: titleBar.minY, width: titleBar.width, height: 10).fill()

        // 红黄绿
        let dotColors: [NSColor] = [
            NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.35, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1)
        ]
        for (index, color) in dotColors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: rect.minX + 14 + CGFloat(index) * 18,
                y: rect.maxY - 23,
                width: 11, height: 11
            )).fill()
        }

        drawText(title, at: CGPoint(x: rect.minX + 78, y: rect.maxY - 24), size: 11.5, color: NSColor.white.withAlphaComponent(0.85))

        // 内容行
        var y = rect.maxY - 62
        for index in 0..<bodyLines {
            let width = rect.width * (index == bodyLines - 1 ? 0.42 : 0.78)
            NSColor(calibratedWhite: 0.32, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: CGRect(x: rect.minX + 24, y: y, width: width, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            if index == 2 {
                accent.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: CGRect(x: rect.minX + 24, y: y - 8, width: 90, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            }
            y -= 24
            if y < rect.minY + 24 { break }
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color
        ]
        NSAttributedString(string: text, attributes: attributes).draw(at: point)
    }
}
