import AppKit
import CoreImage

// MARK: - 笔画模型

/// 一条标注笔画。坐标使用画布显示坐标（pt，原点左下、y 向上）；
/// 导出时按 `图片像素宽 / 画布显示宽` 的比例换算到原生像素。
struct AnnotationStroke {
    /// 模糊工具的样式：高斯模糊 / 马赛克（像素化）。
    enum BlurStyle: Int {
        case gaussian
        case pixelate

        var title: String {
            switch self {
            case .gaussian: return "高斯模糊"
            case .pixelate: return "马赛克"
            }
        }
    }

    /// 聚光灯工具的样式：黑色半透明压暗 / 白色半透明提亮（矩形内始终保持原亮度）。
    enum SpotlightStyle: Int {
        case dark
        case light

        var title: String {
            switch self {
            case .dark: return "压暗"
            case .light: return "提亮"
            }
        }

        /// 聚光区域外的遮罩颜色。
        var overlayColor: NSColor {
            switch self {
            case .dark: return NSColor.black.withAlphaComponent(0.62)
            case .light: return NSColor.white.withAlphaComponent(0.72)
            }
        }
    }

    /// 工具类型：前 6 个是工具栏主工具，后 7 个是「更多工具」里的扩展工具。
    enum Tool: Int, CaseIterable {
        case pen
        case line
        case arrow
        case rectangle
        case highlighter
        case eraser
        case text
        case step
        case blur
        case spotlight
        case eyedropper
        case ruler
        case loupe

        /// 工具栏主工具（保持 6 个不变）
        static let primaryTools: [Tool] = [.pen, .line, .arrow, .rectangle, .highlighter, .eraser]
        /// 「更多工具」弹窗中的扩展工具
        static let extendedTools: [Tool] = [.text, .step, .blur, .spotlight, .eyedropper, .ruler, .loupe]

        /// 是否属于「更多工具」扩展组
        var isExtended: Bool {
            switch self {
            case .text, .step, .blur, .spotlight, .eyedropper, .ruler, .loupe: return true
            default: return false
            }
        }

        /// 是否是不产生持久笔画、只在画布上临时交互的工具（取色 / 测量 / 放大镜）。
        var isTransient: Bool {
            switch self {
            case .eyedropper, .ruler, .loupe: return true
            default: return false
            }
        }

        var symbolName: String {
            switch self {
            case .pen: return "pencil.tip"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .highlighter: return "highlighter"
            case .eraser: return "eraser"
            case .text: return "textformat"
            case .step: return "1.circle"
            case .blur: return "square.grid.3x3"
            case .spotlight: return "flashlight.on.fill"
            case .eyedropper: return "eyedropper"
            case .ruler: return "ruler"
            case .loupe: return "magnifyingglass"
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
            case .text: return "文字"
            case .step: return "序号"
            case .blur: return "模糊"
            case .spotlight: return "聚光灯"
            case .eyedropper: return "取色器"
            case .ruler: return "测量"
            case .loupe: return "放大镜"
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
            case .text: return "T"
            case .step: return "N"
            case .blur: return "B"
            case .spotlight: return "G"
            case .eyedropper: return "I"
            case .ruler: return "M"
            case .loupe: return "Z"
            }
        }
    }

    var tool: Tool
    /// 画笔 / 高亮：完整轨迹；直线 / 箭头 / 矩形 / 模糊 / 聚光灯：起点 + 终点；
    /// 文字 / 序号：锚点（文字为左上角，序号为圆心）。
    var points: [CGPoint]
    var color: NSColor
    /// 线宽（显示坐标 pt）。文字工具里存字号、序号工具里用于换算圆的半径。
    var lineWidth: CGFloat
    /// 文字工具的文本内容
    var text: String? = nil
    /// 序号工具的自增编号
    var stepNumber: Int? = nil
    /// 模糊工具的效果样式
    var blurStyle: BlurStyle? = nil
    /// 聚光灯工具的样式（黑色压暗 / 白色提亮）
    var spotlightStyle: SpotlightStyle? = nil

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
            && lhs.text == rhs.text
            && lhs.stepNumber == rhs.stepNumber
            && lhs.blurStyle == rhs.blurStyle
            && lhs.spotlightStyle == rhs.spotlightStyle
    }
}

// MARK: - 背景板

/// 导出背景板（Backdrop）设置：与笔画 / 撤销无关，只影响画布预览与导出合成。
struct AnnotationBackdrop: Equatable {
    /// 4 个预设底色
    enum Preset: Int, CaseIterable {
        case paper
        case graphite
        case white
        case signalOrange

        var title: String {
            switch self {
            case .paper: return "纸白"
            case .graphite: return "石墨"
            case .white: return "纯白"
            case .signalOrange: return "信号橙"
            }
        }

        var hex: String {
            switch self {
            case .paper: return "#F3F0E8"
            case .graphite: return "#24282C"
            case .white: return "#FFFFFF"
            case .signalOrange: return "#E8551F"
            }
        }

        var color: NSColor {
            switch self {
            case .paper:
                return NSColor(srgbRed: 0xF3 / 255, green: 0xF0 / 255, blue: 0xE8 / 255, alpha: 1)
            case .graphite:
                return NSColor(srgbRed: 0x24 / 255, green: 0x28 / 255, blue: 0x2C / 255, alpha: 1)
            case .white:
                return .white
            case .signalOrange:
                return NSColor(srgbRed: 0xE8 / 255, green: 0x55 / 255, blue: 0x1F / 255, alpha: 1)
            }
        }

        /// 浅色底用深色描边、深色底用白色描边
        var isLight: Bool { self == .paper || self == .white }
    }

    /// 内边距档位：按图片短边像素的 6% / 9% / 12%
    enum Padding: Int, CaseIterable {
        case narrow
        case medium
        case wide

        var title: String {
            switch self {
            case .narrow: return "窄"
            case .medium: return "中"
            case .wide: return "宽"
            }
        }

        var ratio: CGFloat {
            switch self {
            case .narrow: return 0.06
            case .medium: return 0.09
            case .wide: return 0.12
            }
        }

        var caption: String { "内边距 \(Int((ratio * 100).rounded()))%" }
    }

    var isEnabled = false
    var preset: Preset = .graphite
    var padding: Padding = .medium
    var rounded = true
    var shadow = true
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
    /// 画布在屏幕上的显示尺寸（pt）；可能小于 image.pointSize。
    /// 背景板开关会等比缩放该尺寸（同时缩放已有笔画），保证标注仍与图片对齐。
    private(set) var displaySize: CGSize

    /// 当前工具
    var tool: AnnotationStroke.Tool = .pen {
        didSet {
            // 切换工具即清除测量结果 / 未完成的拖拽，保证「保留到切换工具」的语义
            if tool != oldValue {
                currentStroke = nil
                activeRuler = nil
                committedRuler = nil
                loupePoint = nil
            }
            // 放大镜需要持续接收 mouseMoved
            window?.acceptsMouseMovedEvents = (tool == .loupe)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    /// 当前颜色
    var strokeColor: NSColor = .white
    /// 当前粗细（pt）；高亮固定 14、矩形固定 1.5、文字换算成字号、序号换算成圆半径
    var lineWidth: CGFloat = 4
    /// 模糊工具当前样式（高斯 / 马赛克），由「更多工具」弹窗切换
    var blurStyle: AnnotationStroke.BlurStyle = .pixelate
    /// 聚光灯当前样式（压暗 / 提亮），由「更多工具」弹窗切换
    var spotlightStyle: AnnotationStroke.SpotlightStyle = .dark {
        didSet { needsDisplay = true }
    }
    /// 背景板设置（预览由工作台绘制、导出由 compositeImage 合成；与撤销无关）
    var backdrop = AnnotationBackdrop() {
        didSet {
            guard backdrop != oldValue else { return }
            applyBackdropAppearance()
            needsDisplay = true
        }
    }

    /// 画布上图片区域的圆角（显示 pt）：背景板关闭保持 8；开启后由「圆角」开关决定
    var imageCornerRadius: CGFloat {
        backdrop.isEnabled && !backdrop.rounded ? 0 : 8
    }
    /// 背景板卡片圆角（显示 pt）
    var backdropCardCornerRadius: CGFloat {
        backdrop.isEnabled && backdrop.rounded ? 14 : 0
    }
    /// 背景板在画布外围的内边距（显示 pt，按短边比例）；关闭时为 0
    var backdropPaddingDisplay: CGFloat {
        guard backdrop.isEnabled else { return 0 }
        return (min(displaySize.width, displaySize.height) * backdrop.padding.ratio).rounded()
    }

    /// 笔画/撤销状态变化时回调（刷新工具栏按钮）
    var onEditStateChanged: (() -> Void)?
    /// 取色器取到颜色并写入剪贴板后回调（hex, 颜色），仅用于底部临时提示，不进入笔画
    var onColorPicked: ((String, NSColor) -> Void)?

    // MARK: 内部状态

    private(set) var strokes: [AnnotationStroke] = []
    private var currentStroke: AnnotationStroke?
    private var undoStack: [[AnnotationStroke]] = []
    private var redoStack: [[AnnotationStroke]] = []
    private var eraseSnapshot: [AnnotationStroke]?
    private var eraseChanged = false

    /// 测量工具的一次完整拖拽（画布显示坐标 pt）。不进入笔画、不参与导出。
    private struct RulerMeasurement {
        var start: CGPoint
        var end: CGPoint
    }
    /// 正在拖拽中的测量 / 松手后保留到切换工具的测量
    private var activeRuler: RulerMeasurement?
    private var committedRuler: RulerMeasurement?

    /// 放大镜当前取样点（画布显示坐标）；仅显示、不进入笔画、不导出
    private(set) var loupePoint: CGPoint?
    private var loupeTrackingArea: NSTrackingArea?

    // 文字工具的内联输入框状态
    private var textEditor: NSTextField?
    private var textEditAnchor: CGPoint = .zero
    private var textEditColor: NSColor = .white
    private var textEditFontSize: CGFloat = 16

    // 模糊滤镜缓存：同一区域 / 样式只渲染一次，拖动时实时预览不卡顿
    private struct BlurCacheKey: Hashable {
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let style: Int
        let strength: Int
    }
    private var blurCache: [BlurCacheKey: CGImage] = [:]
    private var blurCacheOrder: [BlurCacheKey] = []
    /// 缓存估算内存（上限约 64MB，避免大截图拖拽时缓存过多区域）
    private var blurCacheBytes = 0
    private static let blurCacheByteLimit = 64 * 1024 * 1024
    private lazy var ciContext = CIContext()

    private let nsImage: NSImage
    private lazy var eraserCursor: NSCursor = AnnotationCanvasView.makeEraserCursor()

    // MARK: 初始化

    init(frame frameRect: NSRect, image: PinnedImage, displaySize: CGSize) {
        self.image = image
        self.displaySize = displaySize
        self.nsImage = image.nsImage
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = imageCornerRadius
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

    /// 调试 / 离屏渲染：预置一条测量结果（测量不产生持久笔画，仅用于截图自检）。
    func debugSetRulerMeasurement(start: CGPoint, end: CGPoint) {
        committedRuler = RulerMeasurement(start: start, end: end)
        activeRuler = nil
        needsDisplay = true
    }

    // MARK: 绘制

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        layer?.cornerRadius = imageCornerRadius
        window?.acceptsMouseMovedEvents = (tool == .loupe)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 图片：圆角裁切后等比铺满
        context.saveGState()
        let clip = CGPath(
            roundedRect: bounds,
            cornerWidth: imageCornerRadius,
            cornerHeight: imageCornerRadius,
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

        // 测量覆层：只画在画布上（导出路径 compositeImage 不会走到这里）
        if let ruler = activeRuler ?? committedRuler {
            drawRuler(ruler, in: context)
        }

        // 放大镜覆层：鼠标移动时跟随，只显示、不导出（导出只走 draw(stroke:)）
        if let loupePoint {
            drawLoupe(at: loupePoint, in: context)
        }

        // 画布描边：深色底 1px 白色 10%，浅色背景板上用深色描边
        let borderColor: NSColor
        if backdrop.isEnabled && backdrop.preset.isLight {
            borderColor = NSColor.black.withAlphaComponent(0.10)
        } else {
            borderColor = NSColor.white.withAlphaComponent(0.10)
        }
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: imageCornerRadius,
            yRadius: imageCornerRadius
        )
        border.lineWidth = 1
        borderColor.setStroke()
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

        case .text:
            context.restoreGState()
            drawText(stroke, in: context)
            return

        case .step:
            context.restoreGState()
            drawStep(stroke, in: context)
            return

        case .blur:
            context.restoreGState()
            drawBlur(stroke, in: context)
            return

        case .spotlight:
            context.restoreGState()
            drawSpotlight(stroke, in: context)
            return

        case .eyedropper, .ruler, .loupe:
            // 瞬时工具不产生持久笔画；测量 / 放大镜覆层单独绘制
            break

        case .eraser:
            break
        }

        context.restoreGState()
    }

    /// 文字：按当前颜色 / 字号绘制，锚点是文字左上角。
    private func drawText(_ stroke: AnnotationStroke, in context: CGContext) {
        guard let text = stroke.text, !text.isEmpty, let anchor = stroke.points.first else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: stroke.lineWidth, weight: .semibold),
            .foregroundColor: stroke.color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        guard size.width > 0, size.height > 0 else { return }
        // 画布 y 向上：锚点是文字左上角，因此绘制矩形位于锚点下方
        let rect = CGRect(
            x: anchor.x,
            y: anchor.y - size.height,
            width: ceil(size.width) + 4,
            height: ceil(size.height) + 2
        )
        // NSAttributedString.draw 需要 NSGraphicsContext；导出时可临时包一层
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(in: rect)
        NSGraphicsContext.current = previous
    }

    /// 序号：橙色实心圆 + 白色数字（居中对齐）。
    private func drawStep(_ stroke: AnnotationStroke, in context: CGContext) {
        guard let center = stroke.points.first, let number = stroke.stepNumber else { return }
        let radius = AnnotationCanvasView.stepRadius(forLineWidth: stroke.lineWidth)
        context.saveGState()
        context.setFillColor(AnnotationCanvasView.stepFillColor.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        // 深色描边让橙圆在浅色背景上也清晰
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.restoreGState()

        let fontSize = max(9, radius * 1.15)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = attributed.size()
        let rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: ceil(size.width) + 2,
            height: ceil(size.height) + 2
        )
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(in: rect)
        NSGraphicsContext.current = previous
    }

    /// 模糊 / 马赛克：把原图对应区域经 Core Image 处理后盖回画布（画布与导出共用）。
    private func drawBlur(_ stroke: AnnotationStroke, in context: CGContext) {
        guard let rect = normalizedRect(for: stroke), rect.width >= 1, rect.height >= 1 else { return }
        guard let filtered = filteredBlurImage(for: stroke, rect: rect) else {
            // 兜底：Core Image 不可用时压暗该区域，至少给出视觉反馈
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
            context.fill(rect)
            context.restoreGState()
            return
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(filtered, in: rect)
        context.restoreGState()
    }

    /// 聚光灯：矩形外铺半透明黑（或白），矩形内保持原亮度；圆角让边缘更柔和（画布与导出共用）。
    private func drawSpotlight(_ stroke: AnnotationStroke, in context: CGContext) {
        guard let rect = normalizedRect(for: stroke) else { return }
        let style = stroke.spotlightStyle ?? spotlightStyle
        let radius = min(12, min(rect.width, rect.height) / 2)
        // even-odd 挖孔：外层 = 整块画布，内层 = 圆角聚光区域
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        context.saveGState()
        context.addPath(mask)
        context.setFillColor(style.overlayColor.cgColor)
        context.fillPath(using: .evenOdd)
        // 聚光区域细描边，让边界在深浅背景上都可辨认
        let border = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(border)
        let borderColor = style == .dark
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.18)
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    /// 对原图的一块区域应用 CIGaussianBlur / CIPixellate，并按像素分辨率缓存。
    private func filteredBlurImage(for stroke: AnnotationStroke, rect: CGRect) -> CGImage? {
        let cgImage = image.cgImage
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        guard pixelWidth >= 1, pixelHeight >= 1,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let scaleX = pixelWidth / bounds.width
        let scaleY = pixelHeight / bounds.height
        // 画布显示坐标（原点左下）→ CGImage 裁剪坐标（原点左上）
        var cropX = floor(rect.minX * scaleX)
        var cropTop = floor(pixelHeight - rect.maxY * scaleY)
        let style = stroke.blurStyle ?? blurStyle
        let pointScale = (scaleX + scaleY) / 2
        let radiusPx = max(2, (8 + stroke.lineWidth * 2) * pointScale)
        let blockPx = max(2, (6 + stroke.lineWidth * 2) * pointScale)
        var cropWidth = min(pixelWidth - cropX, max(1, (rect.width * scaleX).rounded()))
        var cropHeight = min(pixelHeight - cropTop, max(1, (rect.height * scaleY).rounded()))
        cropX = max(0, min(cropX, pixelWidth - 1))
        cropTop = max(0, min(cropTop, pixelHeight - 1))
        cropWidth = max(1, min(cropWidth, pixelWidth - cropX))
        cropHeight = max(1, min(cropHeight, pixelHeight - cropTop))
        let cropRect = CGRect(x: cropX, y: cropTop, width: cropWidth, height: cropHeight)
        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }

        let strength = Int((style == .gaussian ? radiusPx : blockPx).rounded())
        let key = BlurCacheKey(
            originX: Int(cropX),
            originY: Int(cropTop),
            width: Int(cropWidth),
            height: Int(cropHeight),
            style: style.rawValue,
            strength: strength
        )
        if let cached = blurCache[key] {
            return cached
        }

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        let input = CIImage(cgImage: cropped)
        let output: CIImage?
        switch style {
        case .gaussian:
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(radiusPx, forKey: kCIInputRadiusKey)
            output = filter.outputImage?.cropped(to: input.extent)
        case .pixelate:
            guard let filter = CIFilter(name: "CIPixellate") else { return nil }
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(blockPx, forKey: kCIInputScaleKey)
            filter.setValue(
                CIVector(cgPoint: CGPoint(x: input.extent.midX, y: input.extent.midY)),
                forKey: kCIInputCenterKey
            )
            output = filter.outputImage?.cropped(to: input.extent)
        }
        guard let output,
              let filtered = ciContext.createCGImage(output, from: input.extent) else { return nil }

        // 只缓存中小区域；超大区域的拖拽预览直接每次现算，避免内存暴涨
        let bytes = Int(cropRect.width * cropRect.height) * 4
        if bytes <= Self.blurCacheByteLimit / 4 {
            blurCache[key] = filtered
            blurCacheOrder.append(key)
            blurCacheBytes += bytes
            while let expired = blurCacheOrder.first,
                  blurCacheOrder.count > 16 || blurCacheBytes > Self.blurCacheByteLimit {
                blurCacheOrder.removeFirst()
                if let removed = blurCache.removeValue(forKey: expired) {
                    blurCacheBytes -= Int(removed.width * removed.height) * 4
                }
            }
        }
        return filtered
    }

    /// 起点 + 终点 → 标准化矩形；不足两个点时返回 nil。
    private func normalizedRect(for stroke: AnnotationStroke) -> CGRect? {
        guard let first = stroke.points.first, let last = stroke.points.last,
              stroke.points.count >= 2 else { return nil }
        let rect = CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    // MARK: 测量（不进入笔画、不导出）

    /// 测量覆层：包围盒虚线 + 斜线 + 端点 + 原生像素尺寸标签。
    /// 只在画布 `draw(_:)` 里调用，`compositeImage()` 不会走到这里，因此不会导出。
    private func drawRuler(_ measurement: RulerMeasurement, in context: CGContext) {
        let start = measurement.start
        let end = measurement.end
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard hypot(dx, dy) >= 1 else { return }

        let cgImage = image.cgImage
        let scaleX = CGFloat(cgImage.width) / max(bounds.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(bounds.height, 1)
        let pixelWidth = max(1, Int((abs(dx) * scaleX).rounded()))
        let pixelHeight = max(1, Int((abs(dy) * scaleY).rounded()))
        let diagonal = max(1, Int(hypot(dx * scaleX, dy * scaleY).rounded()))
        let boundingRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(dx),
            height: abs(dy)
        )

        context.saveGState()
        // 包围盒：白色细虚线，直观显示宽高对应的区域
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.stroke(boundingRect)

        // 斜线：先深色描边再白色虚线，深浅背景都清晰
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.40).cgColor)
        context.setLineWidth(3)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1.4)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        // 两个端点
        for point in [start, end] {
            let radius: CGFloat = 3.2
            let dotRect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: dotRect)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.40).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: dotRect)
        }
        context.restoreGState()

        // 尺寸标签：宽 × 高 / 斜线长度，全部按截图原生像素换算
        let lines = [
            "宽 \(pixelWidth) × 高 \(pixelHeight) px",
            "斜线 \(diagonal) px"
        ]
        drawRulerLabels(
            lines,
            near: CGPoint(x: boundingRect.midX, y: boundingRect.midY),
            in: context
        )
    }

    /// 测量标签：深色圆角胶囊 + 两行等宽数字，跟随测量中心并自动避免出画布。
    private func drawRulerLabels(_ lines: [String], near center: CGPoint, in context: CGContext) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let lineHeight: CGFloat = 15
        let paddingH: CGFloat = 9
        let paddingV: CGFloat = 5
        let textWidth = lines
            .map { NSAttributedString(string: $0, attributes: attributes).size().width }
            .max() ?? 0
        let boxWidth = min(ceil(textWidth) + paddingH * 2, max(bounds.width - 12, 40))
        let boxHeight = lineHeight * CGFloat(lines.count) + paddingV * 2
        var originX = center.x + 14
        var originY = center.y - boxHeight / 2
        if originX + boxWidth > bounds.maxX - 6 {
            originX = center.x - 14 - boxWidth
        }
        originX = min(max(originX, bounds.minX + 6), max(bounds.minX + 6, bounds.maxX - 6 - boxWidth))
        originY = min(max(originY, bounds.minY + 6), max(bounds.minY + 6, bounds.maxY - 6 - boxHeight))
        let boxRect = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)

        context.saveGState()
        let path = CGPath(roundedRect: boxRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.setFillColor(NSColor(srgbRed: 0.09, green: 0.08, blue: 0.08, alpha: 0.92).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let rect = CGRect(
                x: boxRect.minX + paddingH,
                y: boxRect.maxY - paddingV - lineHeight * CGFloat(index + 1),
                width: boxRect.width - paddingH * 2,
                height: lineHeight
            )
            attributed.draw(in: rect)
        }
        NSGraphicsContext.current = previous
    }

    // MARK: 取色器（不进入笔画、不导出）

    /// 点击画布 → 从原图取像素颜色，复制 #RRGGBB，并回调底部临时提示。
    func pickAndCopyColor(at point: CGPoint) {
        guard let picked = sampleColor(at: point) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(picked.hex, forType: .string)
        onColorPicked?(picked.hex, picked.color)
    }

    /// 读取原图在指定画布点上的像素颜色（按原生像素取色，而不是缩放后的显示图）。
    func sampleColor(at point: CGPoint) -> (hex: String, color: NSColor)? {
        let cgImage = image.cgImage
        guard cgImage.width > 0, cgImage.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        // 画布显示坐标（原点左下、y 向上）→ 位图坐标（原点左上）
        let pixelX = Int((point.x / bounds.width * CGFloat(cgImage.width)).rounded(.down))
        let pixelY = Int(((bounds.height - point.y) / bounds.height * CGFloat(cgImage.height)).rounded(.down))
        let x = min(max(pixelX, 0), cgImage.width - 1)
        let y = min(max(pixelY, 0), cgImage.height - 1)
        guard let cropped = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let color = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        let hex = String(format: "#%02X%02X%02X", Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        return (hex, color)
    }

    // MARK: 放大镜 / 对比度（不进入笔画、不导出）

    /// WCAG 相对亮度 → 对白 / 对黑对比度（1...21）。
    static func wcagContrastRatios(for color: NSColor) -> (white: CGFloat, black: CGFloat) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return (1, 1) }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        let white = 1.05 / (luminance + 0.05)
        let black = (luminance + 0.05) / 0.05
        return (white, black)
    }

    /// 放大镜：在远离取样点的角落显示 4–8x 最近邻放大、中心像素高亮，
    /// 并显示 hex / RGB 与对白、对黑的 WCAG 对比度。
    private func drawLoupe(at samplePoint: CGPoint, in context: CGContext) {
        guard let sample = sampleColor(at: samplePoint) else { return }
        let cgImage = image.cgImage
        guard cgImage.width > 0, cgImage.height > 0,
              bounds.width > 4, bounds.height > 4 else { return }

        let nativeScale = (CGFloat(cgImage.width) / bounds.width
            + CGFloat(cgImage.height) / bounds.height) / 2
        let zoom = min(8, max(4, (nativeScale * 3).rounded()))
        let side = min(140, max(72, min(bounds.width, bounds.height) * 0.7))
        let margin: CGFloat = 12
        // 在四角中选离取样点最远的一个，避免遮住正在检查的位置
        let cornerCandidates = [
            CGPoint(x: bounds.minX + margin, y: bounds.minY + margin),
            CGPoint(x: bounds.maxX - margin - side, y: bounds.minY + margin),
            CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin - side),
            CGPoint(x: bounds.maxX - margin - side, y: bounds.maxY - margin - side)
        ]
        let halfSide = side / 2
        let bestCorner = cornerCandidates.max { lhs, rhs in
            let lhsDistance = hypot(lhs.x + halfSide - samplePoint.x, lhs.y + halfSide - samplePoint.y)
            let rhsDistance = hypot(rhs.x + halfSide - samplePoint.x, rhs.y + halfSide - samplePoint.y)
            return lhsDistance < rhsDistance
        } ?? cornerCandidates[0]
        let loupeRect = CGRect(x: bestCorner.x, y: bestCorner.y, width: side, height: side)

        // 取样点 → 源像素（位图坐标原点左上）
        let pixelX = min(
            max(Int((samplePoint.x / bounds.width * CGFloat(cgImage.width)).rounded(.down)), 0),
            cgImage.width - 1
        )
        let pixelY = min(
            max(Int(((bounds.height - samplePoint.y) / bounds.height * CGFloat(cgImage.height)).rounded(.down)), 0),
            cgImage.height - 1
        )

        // 放大窗口取奇数个源像素，让中心像素正好落在镜片中心
        var span = max(3, Int((side / zoom).rounded()))
        if span % 2 == 0 { span += 1 }
        span = min(span, min(cgImage.width, cgImage.height))
        if span % 2 == 0 { span = max(1, span - 1) }
        let cropX = min(max(pixelX - span / 2, 0), max(0, cgImage.width - span))
        let cropY = min(max(pixelY - span / 2, 0), max(0, cgImage.height - span))
        guard let cropped = cgImage.cropping(
            to: CGRect(x: cropX, y: cropY, width: span, height: span)
        ) else { return }

        // 画布上的取样点标记
        drawLoupeSampleMarker(at: samplePoint, in: context)

        // 圆形镜片：阴影 → 黑色底 → 圆形裁剪 → 最近邻放大
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -3),
            blur: 10,
            color: NSColor.black.withAlphaComponent(0.45).cgColor
        )
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: loupeRect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addEllipse(in: loupeRect)
        context.clip()
        context.interpolationQuality = .none
        context.draw(cropped, in: loupeRect)

        // 中心像素高亮（白色 + 黑色双层描边）
        let pixelSide = side / CGFloat(span)
        let centerX = loupeRect.minX + (CGFloat(pixelX - cropX) + 0.5) * pixelSide
        let centerY = loupeRect.maxY - (CGFloat(pixelY - cropY) + 0.5) * pixelSide
        let pixelRect = CGRect(
            x: centerX - pixelSide / 2,
            y: centerY - pixelSide / 2,
            width: pixelSide,
            height: pixelSide
        )
        context.setLineWidth(1.5)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(pixelRect)
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.stroke(pixelRect.insetBy(dx: -1, dy: -1))
        context.restoreGState()

        // 外圈双色描边
        context.saveGState()
        context.setLineWidth(2)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.strokeEllipse(in: loupeRect.insetBy(dx: 1, dy: 1))
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.strokeEllipse(in: loupeRect.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()

        // 信息胶囊：放大倍数 / hex / RGB / 对白黑对比度
        let ratios = AnnotationCanvasView.wcagContrastRatios(for: sample.color)
        let rgb = sample.color.usingColorSpace(.sRGB) ?? sample.color
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        let lines = [
            "\(Int(zoom))×  \(sample.hex)  RGB \(red),\(green),\(blue)",
            "对白 \(String(format: "%.1f", ratios.white)):1 · 对黑 \(String(format: "%.1f", ratios.black)):1"
        ]
        drawLoupeBadge(lines, near: loupeRect, in: context)
    }

    /// 取样点：白色 + 黑色两遍十字线，任意截图底色上都可见。
    private func drawLoupeSampleMarker(at point: CGPoint, in context: CGContext) {
        let arm: CGFloat = 7
        context.saveGState()
        context.setLineWidth(3)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.move(to: CGPoint(x: point.x - arm, y: point.y))
        context.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - arm))
        context.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.strokePath()
        context.setLineWidth(1.2)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.move(to: CGPoint(x: point.x - arm, y: point.y))
        context.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - arm))
        context.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.strokePath()
        context.restoreGState()
    }

    /// 放大镜信息胶囊：放在镜片下方（空间不足时放上方），始终留在画布内。
    private func drawLoupeBadge(_ lines: [String], near loupeRect: CGRect, in context: CGContext) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let lineHeight: CGFloat = 13
        let paddingH: CGFloat = 8
        let paddingV: CGFloat = 4
        let textWidth = lines
            .map { NSAttributedString(string: $0, attributes: attributes).size().width }
            .max() ?? 0
        let boxWidth = min(ceil(textWidth) + paddingH * 2, max(bounds.width - 12, 60))
        let boxHeight = lineHeight * CGFloat(lines.count) + paddingV * 2
        var originX = loupeRect.midX - boxWidth / 2
        var originY = loupeRect.minY - 6 - boxHeight
        if originY < bounds.minY + 6 {
            originY = loupeRect.maxY + 6
        }
        originX = min(max(originX, bounds.minX + 6), max(bounds.minX + 6, bounds.maxX - 6 - boxWidth))
        originY = min(max(originY, bounds.minY + 6), max(bounds.minY + 6, bounds.maxY - 6 - boxHeight))
        let boxRect = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)

        context.saveGState()
        let path = CGPath(roundedRect: boxRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.setFillColor(NSColor(srgbRed: 0.09, green: 0.08, blue: 0.08, alpha: 0.92).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let rect = CGRect(
                x: boxRect.minX + paddingH,
                y: boxRect.maxY - paddingV - lineHeight * CGFloat(index + 1),
                width: boxRect.width - paddingH * 2,
                height: lineHeight
            )
            attributed.draw(in: rect)
        }
        NSGraphicsContext.current = previous
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
        let cursor: NSCursor
        switch tool {
        case .eraser: cursor = eraserCursor
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let loupeTrackingArea {
            removeTrackingArea(loupeTrackingArea)
        }
        // 放大镜依赖 mouseMoved 实时更新取样点；其它工具下事件被忽略
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        loupeTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .loupe else { return }
        loupePoint = clampPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard tool == .loupe else { return }
        loupePoint = nil
        needsDisplay = true
    }

    /// 调试 / 离屏渲染：预置放大镜取样点（不生成笔画，仅用于截图自检）。
    func debugSetLoupePoint(_ point: CGPoint?) {
        loupePoint = point
        needsDisplay = true
    }

    // MARK: 背景板布局 / 导出

    /// 背景板圆角变化后同步图片图层裁切圆角（预览用）。
    private func applyBackdropAppearance() {
        layer?.cornerRadius = imageCornerRadius
    }

    /// 背景板开关 / 档位变化时调整画布显示尺寸：已有笔画等比缩放，
    /// 保证标注仍与图片严格对齐，导出比例不变。
    func setDisplaySize(_ newSize: CGSize) {
        guard newSize.width >= 1, newSize.height >= 1 else { return }
        let old = displaySize
        guard old.width >= 1, old.height >= 1 else {
            displaySize = newSize
            needsDisplay = true
            return
        }
        let scaleX = newSize.width / old.width
        let scaleY = newSize.height / old.height
        guard abs(scaleX - 1) > 0.0005 || abs(scaleY - 1) > 0.0005 else { return }
        let uniformScale = (scaleX + scaleY) / 2

        func scaledPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scaleX, y: point.y * scaleY)
        }
        func scaledStroke(_ stroke: AnnotationStroke) -> AnnotationStroke {
            var copy = stroke
            copy.points = stroke.points.map(scaledPoint)
            copy.lineWidth *= uniformScale
            return copy
        }
        func scaledRuler(_ ruler: RulerMeasurement) -> RulerMeasurement {
            RulerMeasurement(start: scaledPoint(ruler.start), end: scaledPoint(ruler.end))
        }

        strokes = strokes.map(scaledStroke)
        undoStack = undoStack.map { $0.map(scaledStroke) }
        redoStack = redoStack.map { $0.map(scaledStroke) }
        if let current = currentStroke { currentStroke = scaledStroke(current) }
        if let snapshot = eraseSnapshot { eraseSnapshot = snapshot.map(scaledStroke) }
        if let ruler = activeRuler { activeRuler = scaledRuler(ruler) }
        if let ruler = committedRuler { committedRuler = scaledRuler(ruler) }
        if let point = loupePoint { loupePoint = scaledPoint(point) }
        // 模糊缓存按显示坐标做键，尺寸变化后全部失效
        blurCache.removeAll()
        blurCacheOrder.removeAll()
        blurCacheBytes = 0

        displaySize = newSize
        frame = NSRect(origin: frame.origin, size: newSize)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        // 文字输入中：本次点击先提交已有文字，不再新建输入框
        if textEditor != nil {
            finishTextEditing(commit: true)
            return
        }

        if tool == .text {
            beginTextEditing(at: point)
            return
        }

        // 其余工具：键盘事件统一交给工作台根视图处理
        if let workbench = superview {
            window?.makeFirstResponder(workbench)
        }

        if tool == .eraser {
            beginEraseSession()
            erase(at: point)
            return
        }

        if tool == .step {
            commitStep(at: point)
            return
        }

        // 取色器：点击即取色 / 复制，不产生笔画
        if tool == .eyedropper {
            pickAndCopyColor(at: point)
            return
        }

        // 测量：开始一次拖拽，松手后保留
        if tool == .ruler {
            activeRuler = RulerMeasurement(start: point, end: point)
            committedRuler = nil
            needsDisplay = true
            return
        }

        // 放大镜：点击复制当前像素 #RRGGBB，不产生笔画
        if tool == .loupe {
            loupePoint = point
            pickAndCopyColor(at: point)
            needsDisplay = true
            return
        }

        currentStroke = AnnotationStroke(
            tool: tool,
            points: [point],
            color: strokeColor,
            lineWidth: effectiveLineWidth(for: tool),
            blurStyle: tool == .blur ? blurStyle : nil,
            spotlightStyle: tool == .spotlight ? spotlightStyle : nil
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        if tool == .eraser {
            erase(at: point)
            return
        }

        if tool == .eyedropper || tool == .loupe {
            return
        }

        if tool == .ruler {
            guard var ruler = activeRuler else { return }
            ruler.end = point
            activeRuler = ruler
            needsDisplay = true
            return
        }

        guard var stroke = currentStroke else { return }
        switch stroke.tool {
        case .pen, .highlighter:
            if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 {
                return
            }
            stroke.points.append(point)
        case .line, .arrow, .rectangle, .blur, .spotlight:
            if stroke.points.count == 1 {
                stroke.points.append(point)
            } else {
                stroke.points[stroke.points.count - 1] = point
            }
        case .text, .step, .eraser, .eyedropper, .ruler, .loupe:
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
        if tool == .eyedropper || tool == .loupe {
            return
        }
        if tool == .ruler {
            // 过滤误触：长度过短的拖拽不保留
            if let ruler = activeRuler,
               hypot(ruler.end.x - ruler.start.x, ruler.end.y - ruler.start.y) >= 2 {
                committedRuler = ruler
            }
            activeRuler = nil
            needsDisplay = true
            return
        }
        commitCurrentStroke()
    }

    private func effectiveLineWidth(for tool: AnnotationStroke.Tool) -> CGFloat {
        switch tool {
        case .highlighter: return 14
        case .rectangle: return 1.5
        case .text: return AnnotationCanvasView.textFontSize(forLineWidth: lineWidth)
        default: return lineWidth
        }
    }

    // MARK: 文字 / 序号

    /// 画布显示线宽 → 文字字号
    static func textFontSize(forLineWidth width: CGFloat) -> CGFloat {
        max(12, (8 + width * 2).rounded())
    }

    /// 画布显示线宽 → 序号圆半径
    static func stepRadius(forLineWidth width: CGFloat) -> CGFloat {
        max(11, 10 + width)
    }

    /// 序号的橙色（固定值，导出后不受浅色 / 深色外观影响）
    static let stepFillColor = NSColor(srgbRed: 1.00, green: 0.624, blue: 0.039, alpha: 1)

    /// 点击画布 → 出现内联输入框；Enter 提交、Esc 取消、点击别处提交。
    private func beginTextEditing(at point: CGPoint) {
        let fontSize = effectiveLineWidth(for: .text)
        let height = max(28, (fontSize * 1.7).rounded())
        var width: CGFloat = 220
        width = min(width, max(bounds.width, 40))
        var originX = point.x
        var originY = point.y - height
        originX = min(max(originX, 0), max(bounds.width - width, 0))
        originY = min(max(originY, 0), max(bounds.height - height, 0))

        let field = NSTextField(frame: NSRect(x: originX, y: originY, width: width, height: height))
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = strokeColor
        field.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 0.92)
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "输入文字，Enter 确认"
        field.alignment = .left
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        textEditor = field
        textEditAnchor = CGPoint(x: originX, y: originY + height)
        textEditColor = strokeColor
        textEditFontSize = fontSize
        window?.makeFirstResponder(field)
        field.selectText(nil)
        needsDisplay = true
    }

    /// 结束文字输入。`commit` 为 false 时丢弃输入（Esc）。
    private func finishTextEditing(commit: Bool) {
        guard let field = textEditor else { return }
        textEditor = nil
        field.delegate = nil
        // 输入框正在编辑时文本还在 field editor 里，先取出来
        let raw = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let anchor = textEditAnchor
        let color = textEditColor
        let fontSize = textEditFontSize
        if let workbench = superview {
            window?.makeFirstResponder(workbench)
        }
        field.removeFromSuperview()
        needsDisplay = true

        guard commit else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pushUndoSnapshot()
        strokes.append(AnnotationStroke(
            tool: .text,
            points: [anchor],
            color: color,
            lineWidth: fontSize,
            text: text
        ))
        onEditStateChanged?()
    }

    /// 提交当前文字输入（工具栏 / 完成按钮等外部操作前调用）。
    func endTextEditing() {
        finishTextEditing(commit: true)
    }

    private func commitStep(at point: CGPoint) {
        let nextNumber = (strokes.compactMap { $0.stepNumber }.max() ?? 0) + 1
        pushUndoSnapshot()
        strokes.append(AnnotationStroke(
            tool: .step,
            points: [point],
            color: stepColorForStorage,
            lineWidth: effectiveLineWidth(for: .step),
            stepNumber: nextNumber
        ))
        if let workbench = superview {
            window?.makeFirstResponder(workbench)
        }
        needsDisplay = true
        onEditStateChanged?()
    }

    /// 序号颜色固定为橙色（仅用于数据一致性，绘制时不使用）。
    private var stepColorForStorage: NSColor { AnnotationCanvasView.stepFillColor }

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

        case .text:
            guard let rect = textBounds(for: stroke) else { return false }
            return rect.insetBy(dx: -4, dy: -4).contains(point)

        case .step:
            let radius = AnnotationCanvasView.stepRadius(forLineWidth: stroke.lineWidth)
            return hypot(point.x - first.x, point.y - first.y) <= radius + 2

        case .blur, .spotlight:
            guard let rect = normalizedRect(for: stroke) else { return false }
            return rect.contains(point)

        case .eyedropper, .ruler, .loupe, .eraser:
            return false
        }
    }

    /// 文字笔画的绘制包围盒（用当前字体测量）。
    private func textBounds(for stroke: AnnotationStroke) -> CGRect? {
        guard let text = stroke.text, !text.isEmpty, let anchor = stroke.points.first else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: stroke.lineWidth, weight: .semibold)
        ]
        let size = NSAttributedString(string: text, attributes: attributes).size()
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(
            x: anchor.x,
            y: anchor.y - size.height,
            width: ceil(size.width) + 4,
            height: ceil(size.height) + 2
        )
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

    /// 以原生像素分辨率合成「原图 + 所有笔画」；开启背景板时再合成背景板外框。
    /// 未开启背景板时 pointSize 保持原图点尺寸；开启时按内边距等比放大。
    func compositeImage() -> PinnedImage? {
        guard let annotated = compositeAnnotatedImage() else { return nil }
        guard backdrop.isEnabled else {
            return PinnedImage(cgImage: annotated, pointSize: image.pointSize)
        }
        return compositeBackdropImage(annotated)
    }

    /// 「原图 + 所有笔画」的原生像素图（不含背景板）。
    private func compositeAnnotatedImage() -> CGImage? {
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

        return context.makeImage()
    }

    /// 背景板合成：底色铺满 → 图片圆角 + 柔和阴影 → 标注图。
    /// 内边距按图片短边像素的 6% / 9% / 12%。
    private func compositeBackdropImage(_ annotated: CGImage) -> PinnedImage? {
        let pixelWidth = annotated.width
        let pixelHeight = annotated.height
        guard pixelWidth > 0, pixelHeight > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let ratio = backdrop.padding.ratio
        let padPixels = max(1, Int((CGFloat(min(pixelWidth, pixelHeight)) * ratio).rounded()))
        let outputWidth = pixelWidth + padPixels * 2
        let outputHeight = pixelHeight + padPixels * 2
        let colorSpace = annotated.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let imageRect = CGRect(
            x: padPixels,
            y: padPixels,
            width: pixelWidth,
            height: pixelHeight
        )
        let pixelScale = CGFloat(pixelWidth) / bounds.width
        let imageRadius = backdrop.rounded ? max(1, imageCornerRadius * pixelScale) : 0

        // 1. 底色
        context.setFillColor(backdrop.preset.color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        // 2. 图片阴影：用底色填充圆角矩形，只露出柔和阴影
        if backdrop.shadow {
            context.saveGState()
            let shadowRadius = max(4, CGFloat(padPixels) * 0.55)
            context.setShadow(
                offset: CGSize(width: 0, height: -max(2, CGFloat(padPixels) * 0.12)),
                blur: shadowRadius,
                color: NSColor.black.withAlphaComponent(0.32).cgColor
            )
            context.setFillColor(backdrop.preset.color.cgColor)
            let shadowPath = CGPath(
                roundedRect: imageRect,
                cornerWidth: imageRadius,
                cornerHeight: imageRadius,
                transform: nil
            )
            context.addPath(shadowPath)
            context.fillPath()
            context.restoreGState()
        }

        // 3. 标注图：圆角裁切后绘制
        context.saveGState()
        if imageRadius > 0.5 {
            let clip = CGPath(
                roundedRect: imageRect,
                cornerWidth: imageRadius,
                cornerHeight: imageRadius,
                transform: nil
            )
            context.addPath(clip)
            context.clip()
        }
        context.draw(annotated, in: imageRect)
        context.restoreGState()

        // 4. 图片 1px 描边，浅色底用深色、深色底用白色
        if imageRadius > 0.5 {
            let borderColor = backdrop.preset.isLight
                ? NSColor.black.withAlphaComponent(0.10)
                : NSColor.white.withAlphaComponent(0.12)
            context.saveGState()
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(max(1, pixelScale))
            let borderPath = CGPath(
                roundedRect: imageRect.insetBy(dx: pixelScale / 2, dy: pixelScale / 2),
                cornerWidth: max(0, imageRadius - pixelScale / 2),
                cornerHeight: max(0, imageRadius - pixelScale / 2),
                transform: nil
            )
            context.addPath(borderPath)
            context.strokePath()
            context.restoreGState()
        }

        guard let output = context.makeImage() else { return nil }
        // padPixels 换算回点：按原图 native scale 反算，保持贴图尺寸语义
        let pointScale = image.pointSize.width / CGFloat(pixelWidth)
        let pointPadding = CGFloat(padPixels) * pointScale
        let outputPointSize = CGSize(
            width: image.pointSize.width + pointPadding * 2,
            height: image.pointSize.height + pointPadding * 2
        )
        return PinnedImage(cgImage: output, pointSize: outputPointSize)
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

// MARK: - 文字输入框代理

extension AnnotationCanvasView: NSTextFieldDelegate {
    /// Enter 提交、Esc 取消。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishTextEditing(commit: false)
            return true
        }
        return false
    }

    /// 点击别处 / 切走焦点：提交输入内容。
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === textEditor else { return }
        finishTextEditing(commit: true)
    }

    /// 输入过程中随文本长度调整输入框宽度，避免长文本被截断。
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === textEditor else { return }
        let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let attributes: [NSAttributedString.Key: Any] = [
            .font: field.font ?? NSFont.systemFont(ofSize: textEditFontSize)
        ]
        let textWidth = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes).size().width
        let maxWidth = max(40, bounds.width - field.frame.minX)
        let width = min(maxWidth, max(120, textWidth + 24))
        if abs(width - field.frame.width) > 1 {
            var frame = field.frame
            frame.size.width = width
            field.frame = frame
        }
    }
}
