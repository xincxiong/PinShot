import AppKit

// MARK: - 笔画模型

/// 一条标注笔画。坐标使用画布显示坐标（pt，原点左下、y 向上）；
/// 导出时按 `图片像素宽 / 画布显示宽` 的比例换算到原生像素。
struct AnnotationStroke {
    /// 工具类型（与工具栏按钮一一对应）。
    enum Tool: Int, CaseIterable {
        case pen
        case line
        case arrow
        case rectangle
        case highlighter
        case eraser

        var symbolName: String {
            switch self {
            case .pen: return "pencil.tip"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .highlighter: return "highlighter"
            case .eraser: return "eraser"
            }
        }

        var title: String {
            switch self {
            case .pen: return "画笔"
            case .line: return "直线"
            case .arrow: return "箭头"
            case .rectangle: return "矩形"
            case .highlighter: return "高亮"
            case .eraser: return "橡皮擦"
            }
        }

        /// 键盘快捷键（大写）
        var shortcut: String {
            switch self {
            case .pen: return "P"
            case .line: return "L"
            case .arrow: return "A"
            case .rectangle: return "R"
            case .highlighter: return "H"
            case .eraser: return "E"
            }
        }
    }

    var tool: Tool
    /// 画笔 / 高亮：完整轨迹；直线 / 箭头 / 矩形：起点 + 终点。
    var points: [CGPoint]
    var color: NSColor
    /// 线宽（显示坐标 pt）
    var lineWidth: CGFloat

    /// 实际绘制颜色：高亮固定 35% 透明。
    var renderedColor: NSColor {
        tool == .highlighter ? color.withAlphaComponent(0.35) : color
    }
}

extension AnnotationStroke: Equatable {
    static func == (lhs: AnnotationStroke, rhs: AnnotationStroke) -> Bool {
        lhs.tool == rhs.tool
            && lhs.points == rhs.points
            && lhs.lineWidth == rhs.lineWidth
            && lhs.color.isEqual(rhs.color)
    }
}

// MARK: - 画布

/// 标注画布：显示（可能被缩放的）截图 + 所有笔画 + 实时预览，并负责鼠标绘制、橡皮擦与撤销栈。
///
/// 画布坐标体系：非翻转（原点左下、y 向上），与 CoreGraphics 位图坐标一致，
/// 这样导出时无需翻转 y，叠加的笔画与原图严格对齐。
@MainActor
final class AnnotationCanvasView: NSView {

    // MARK: 配置

    let image: PinnedImage
    /// 画布在屏幕上的显示尺寸（pt）；可能小于 image.pointSize
    let displaySize: CGSize

    /// 当前工具
    var tool: AnnotationStroke.Tool = .pen {
        didSet {
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    /// 当前颜色
    var strokeColor: NSColor = .white
    /// 当前粗细（pt）；高亮固定 14、矩形固定 1.5
    var lineWidth: CGFloat = 4

    /// 笔画/撤销状态变化时回调（刷新工具栏按钮）
    var onEditStateChanged: (() -> Void)?

    // MARK: 内部状态

    private(set) var strokes: [AnnotationStroke] = []
    private var currentStroke: AnnotationStroke?
    private var undoStack: [[AnnotationStroke]] = []
    private var redoStack: [[AnnotationStroke]] = []
    private var eraseSnapshot: [AnnotationStroke]?
    private var eraseChanged = false

    private let cornerRadius: CGFloat = 8
    private let nsImage: NSImage
    private lazy var eraserCursor: NSCursor = AnnotationCanvasView.makeEraserCursor()

    // MARK: 初始化

    init(frame frameRect: NSRect, image: PinnedImage, displaySize: CGSize) {
        self.image = image
        self.displaySize = displaySize
        self.nsImage = image.nsImage
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 状态

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(strokes)
        strokes = previous
        needsDisplay = true
        onEditStateChanged?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(strokes)
        strokes = next
        needsDisplay = true
        onEditStateChanged?()
    }

    /// 调试 / 离屏渲染：直接替换示例笔画，并清空撤销栈。
    func setDebugStrokes(_ newStrokes: [AnnotationStroke]) {
        strokes = newStrokes
        currentStroke = nil
        undoStack.removeAll()
        redoStack.removeAll()
        needsDisplay = true
        onEditStateChanged?()
    }

    // MARK: 绘制

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 图片：圆角裁切后等比铺满
        context.saveGState()
        let clip = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(clip)
        context.clip()
        nsImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        )
        context.restoreGState()

        // 已提交笔画 + 正在拖拽的实时预览
        context.saveGState()
        for stroke in strokes {
            draw(stroke, in: context)
        }
        if let currentStroke {
            draw(currentStroke, in: context)
        }
        context.restoreGState()

        // 画布描边：1px 白色 10%
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.10).setStroke()
        border.stroke()
    }

    /// 在 CoreGraphics 上下文中绘制一条笔画（画布与导出共用）。
    private func draw(_ stroke: AnnotationStroke, in context: CGContext) {
        guard let first = stroke.points.first else { return }
        let color = stroke.renderedColor
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(stroke.lineWidth)

        switch stroke.tool {
        case .pen, .highlighter:
            if stroke.points.count < 2 {
                // 单点：画圆点
                let radius = stroke.lineWidth / 2
                context.fillEllipse(in: CGRect(
                    x: first.x - radius, y: first.y - radius,
                    width: radius * 2, height: radius * 2
                ))
            } else {
                context.beginPath()
                context.move(to: stroke.points[0])
                for point in stroke.points.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
            }

        case .line, .arrow:
            guard stroke.points.count >= 2 else { break }
            let last = stroke.points[stroke.points.count - 1]
            context.beginPath()
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
            if stroke.tool == .arrow {
                drawArrowHead(from: first, to: last, lineWidth: stroke.lineWidth, in: context)
            }

        case .rectangle:
            guard stroke.points.count >= 2 else { break }
            let last = stroke.points[stroke.points.count - 1]
            var rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            guard rect.width >= 1, rect.height >= 1 else { break }
            // 设计稿：矩形固定 1.5pt 空心描边
            context.setLineWidth(1.5)
            rect = rect.insetBy(dx: 0.75, dy: 0.75)
            context.stroke(rect)

        case .eraser:
            break
        }

        context.restoreGState()
    }

    /// 实心箭头（箭头长度随线宽变化）。
    private func drawArrowHead(from start: CGPoint, to tip: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let dx = tip.x - start.x
        let dy = tip.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let angle = atan2(dy, dx)
        let headLength = max(lineWidth * 3.2, 10)
        let headWidth = max(lineWidth * 2.4, 8)
        let baseX = tip.x - cos(angle) * headLength
        let baseY = tip.y - sin(angle) * headLength
        let perpendicular = angle + .pi / 2
        let offsetX = cos(perpendicular) * headWidth / 2
        let offsetY = sin(perpendicular) * headWidth / 2
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: baseX + offsetX, y: baseY + offsetY))
        path.addLine(to: CGPoint(x: baseX - offsetX, y: baseY - offsetY))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    // MARK: 鼠标绘制

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: tool == .eraser ? eraserCursor : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        // 键盘事件统一交给工作台根视图处理
        if let workbench = superview {
            window?.makeFirstResponder(workbench)
        }
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        if tool == .eraser {
            beginEraseSession()
            erase(at: point)
            return
        }

        currentStroke = AnnotationStroke(
            tool: tool,
            points: [point],
            color: strokeColor,
            lineWidth: effectiveLineWidth(for: tool)
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        if tool == .eraser {
            erase(at: point)
            return
        }

        guard var stroke = currentStroke else { return }
        switch stroke.tool {
        case .pen, .highlighter:
            if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 {
                return
            }
            stroke.points.append(point)
        case .line, .arrow, .rectangle:
            if stroke.points.count == 1 {
                stroke.points.append(point)
            } else {
                stroke.points[stroke.points.count - 1] = point
            }
        case .eraser:
            break
        }
        currentStroke = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .eraser {
            endEraseSession()
            return
        }
        commitCurrentStroke()
    }

    private func effectiveLineWidth(for tool: AnnotationStroke.Tool) -> CGFloat {
        switch tool {
        case .highlighter: return 14
        case .rectangle: return 1.5
        default: return lineWidth
        }
    }

    // MARK: 提交 / 撤销

    private func commitCurrentStroke() {
        guard let stroke = currentStroke else { return }
        currentStroke = nil
        defer { needsDisplay = true }

        // 过滤误触：点击没有拖动、或长度几乎为零的笔画
        if let first = stroke.points.first, let last = stroke.points.last {
            let distance = hypot(last.x - first.x, last.y - first.y)
            if stroke.tool == .pen || stroke.tool == .highlighter {
                if stroke.points.count < 2 || distance < 1 { return }
            } else if distance < 2 {
                return
            }
        } else {
            return
        }

        pushUndoSnapshot()
        strokes.append(stroke)
        onEditStateChanged?()
    }

    private func pushUndoSnapshot() {
        undoStack.append(strokes)
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
    }

    // MARK: 橡皮擦

    private func beginEraseSession() {
        eraseSnapshot = strokes
        eraseChanged = false
    }

    private func endEraseSession() {
        defer {
            eraseSnapshot = nil
            eraseChanged = false
        }
        guard eraseChanged, let snapshot = eraseSnapshot else { return }
        undoStack.append(snapshot)
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
        onEditStateChanged?()
    }

    private func erase(at point: CGPoint) {
        guard !strokes.isEmpty else { return }
        let remaining = strokes.filter { !hitTest(stroke: $0, point: point) }
        if remaining.count != strokes.count {
            strokes = remaining
            eraseChanged = true
            needsDisplay = true
        }
    }

    /// 判断点是否命中一条笔画（距离阈值随线宽与工具变化）。
    private func hitTest(stroke: AnnotationStroke, point: CGPoint) -> Bool {
        let threshold = max(stroke.lineWidth / 2 + 3, 6)
        let points = stroke.points
        guard let first = points.first else { return false }

        switch stroke.tool {
        case .pen, .highlighter:
            if points.count == 1 {
                return hypot(point.x - first.x, point.y - first.y) <= threshold
            }
            for index in 1..<points.count {
                if distance(from: point, toSegment: points[index - 1], points[index]) <= threshold {
                    return true
                }
            }
            return false

        case .line, .arrow:
            guard let last = points.last else { return false }
            return distance(from: point, toSegment: first, last) <= threshold

        case .rectangle:
            guard let last = points.last else { return false }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
            for index in 0..<4 {
                if distance(from: point, toSegment: corners[index], corners[(index + 1) % 4]) <= threshold {
                    return true
                }
            }
            return false

        case .eraser:
            return false
        }
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func clampPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(bounds.width, 0)),
            y: min(max(point.y, 0), max(bounds.height, 0))
        )
    }

    // MARK: 导出

    /// 以原生像素分辨率合成「原图 + 所有笔画」，pointSize 保持原图点尺寸。
    func compositeImage() -> PinnedImage? {
        let cgImage = image.cgImage
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // 画布显示坐标 → 像素坐标
        let scaleX = CGFloat(pixelWidth) / bounds.width
        let scaleY = CGFloat(pixelHeight) / bounds.height
        context.saveGState()
        context.scaleBy(x: scaleX, y: scaleY)
        for stroke in strokes {
            draw(stroke, in: context)
        }
        context.restoreGState()

        guard let output = context.makeImage() else { return nil }
        return PinnedImage(cgImage: output, pointSize: image.pointSize)
    }

    // MARK: 橡皮擦圆形光标

    /// 20×20 圆形光标：白色环 + 黑色内环，深色 / 浅色截图都清晰。
    private static func makeEraserCursor() -> NSCursor {
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: side - 4, height: side - 4))
            NSColor.white.setStroke()
            circle.lineWidth = 3
            circle.stroke()
            NSColor.black.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
