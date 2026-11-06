import AppKit

// MARK: - 对外接口（CaptureCoordinator 依赖，保持稳定）

enum AnnotationEditorAction {
    case finish
    case copy
    case save
}

enum AnnotationEditorOutcome {
    case completed(PinnedImage, action: AnnotationEditorAction)
    case cancelled
}

// MARK: - 视觉常量

/// 标注工作台的固定配色（不随系统浅色 / 深色变化）。
private enum AnnotationEditorColors {
    /// 工作台底色 #141312
    static let background = NSColor(srgbRed: 0x14 / 255, green: 0x13 / 255, blue: 0x12 / 255, alpha: 1)
    static let backgroundBorder = NSColor.white.withAlphaComponent(0.07)
    static let separator = NSColor.white.withAlphaComponent(0.12)
    static let border = NSColor.white.withAlphaComponent(0.12)
    static let toolIcon = NSColor.white.withAlphaComponent(0.86)
    static let hint = NSColor.white.withAlphaComponent(0.45)
}

/// 标注调色板与粗细档位（与设计文档一致）。
enum AnnotationPalette {
    /// 红 / 橙 / 黄 / 绿 / 蓝 / 白
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.271, blue: 0.227, alpha: 1), // #FF453A
        NSColor(srgbRed: 1.00, green: 0.624, blue: 0.039, alpha: 1), // #FF9F0A
        NSColor(srgbRed: 1.00, green: 0.839, blue: 0.039, alpha: 1), // #FFD60A
        NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 1), // #32D74B
        NSColor(srgbRed: 0.039, green: 0.518, blue: 1.00, alpha: 1), // #0A84FF
        NSColor.white
    ]
    static let colorNames = ["红", "橙", "黄", "绿", "蓝", "白"]
    static let lineWidths: [CGFloat] = [2, 4, 8]
    static let defaultColor = colors[0]
    static let defaultLineWidth: CGFloat = 4
}

// MARK: - 布局常量

private enum AnnotationLayout {
    static let horizontalInset: CGFloat = 24
    static let topInset: CGFloat = 22
    static let bottomInset: CGFloat = 20
    static let toolbarHeight: CGFloat = 44
    static let toolbarToCanvasGap: CGFloat = 14
    static let hintGap: CGFloat = 10
    static let hintHeight: CGFloat = 16
    static let windowCornerRadius: CGFloat = 16

    /// 除画布高度外的固定垂直占用
    static var fixedVertical: CGFloat {
        topInset + toolbarHeight + toolbarToCanvasGap + hintGap + hintHeight + bottomInset
    }
}

private struct AnnotationEditorMetrics {
    let displaySize: CGSize
    let windowSize: CGSize
}

// MARK: - 控制器

/// 截图后的标注编辑器。
///
/// 流程：`present()` 居中弹出固定深色的标注工作台 → 用户画标注 →
/// 「完成 / 复制 / 保存」合成原生像素图后回调 `onFinish`；Esc 取消。
/// `onFinish` 恰好调用一次，且先 `orderOut` 再回调。
@MainActor
final class AnnotationEditorController: NSWindowController {

    private let sourceImage: PinnedImage
    private let onFinish: (AnnotationEditorOutcome) -> Void
    private let metrics: AnnotationEditorMetrics

    private var workbenchView: AnnotationWorkbenchView!
    private var canvasView: AnnotationCanvasView!
    private var toolbarView: AnnotationToolbarView!
    private var finished = false

    // MARK: 初始化

    init(image: PinnedImage, onFinish: @escaping (AnnotationEditorOutcome) -> Void) {
        self.sourceImage = image
        self.onFinish = onFinish
        let metrics = AnnotationEditorController.makeMetrics(for: image)
        self.metrics = metrics

        let panel = AnnotationPanel(
            contentRect: NSRect(origin: .zero, size: metrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configure(panel)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 窗口

    private func configure(_ panel: AnnotationPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // 固定深色工作台：不随系统浅色 / 深色变化
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    private func buildContent() {
        guard let window else { return }

        let canvas = AnnotationCanvasView(
            frame: NSRect(origin: .zero, size: metrics.displaySize),
            image: sourceImage,
            displaySize: metrics.displaySize
        )
        let toolbar = AnnotationToolbarView(target: self)
        let workbench = AnnotationWorkbenchView(
            frame: NSRect(origin: .zero, size: metrics.windowSize),
            canvas: canvas,
            toolbar: toolbar
        )
        workbench.controller = self

        window.contentView = workbench
        workbenchView = workbench
        canvasView = canvas
        toolbarView = toolbar

        canvas.onEditStateChanged = { [weak self] in
            self?.refreshToolbarState()
        }

        selectTool(.pen)
        selectColor(AnnotationPalette.defaultColor)
        selectLineWidth(AnnotationPalette.defaultLineWidth)
        refreshToolbarState()
    }

    // MARK: 展示 / 关闭

    func present() {
        guard let window else { return }
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(workbenchView)
        refreshToolbarState()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        window.setFrameOrigin(origin)
    }

    // MARK: 结束

    /// 唯一的结束出口：保证 onFinish 恰好一次，且先 orderOut 再回调。
    private func finish(_ outcome: AnnotationEditorOutcome) {
        guard !finished else { return }
        finished = true
        dismiss()
        onFinish(outcome)
    }

    private func cancel() {
        finish(.cancelled)
    }

    private func complete(with action: AnnotationEditorAction) {
        guard !finished else { return }
        // 先把当前笔画合成成原生像素图，再关闭窗口
        let annotated = canvasView.compositeImage() ?? sourceImage
        finish(.completed(annotated, action: action))
    }

    // MARK: 选择状态

    func selectTool(_ tool: AnnotationStroke.Tool) {
        canvasView.tool = tool
        toolbarView.setSelectedTool(tool)
    }

    func selectColor(_ color: NSColor) {
        canvasView.strokeColor = color
        toolbarView.setSelectedColor(color)
    }

    func selectLineWidth(_ width: CGFloat) {
        canvasView.lineWidth = width
        toolbarView.setSelectedLineWidth(width)
    }

    private func refreshToolbarState() {
        toolbarView.setSelectedTool(canvasView.tool)
        toolbarView.setSelectedColor(canvasView.strokeColor)
        toolbarView.setSelectedLineWidth(canvasView.lineWidth)
        toolbarView.setUndoRedo(canUndo: canvasView.canUndo, canRedo: canvasView.canRedo)
    }

    private func focusWorkbench() {
        window?.makeFirstResponder(workbenchView)
    }

    // MARK: 键盘

    /// 普通按键：Esc / Return / 工具快捷键。
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            cancel()
            return true
        case 36, 76: // Return / 小键盘 Enter
            complete(with: .finish)
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1 else { return false }
        switch characters {
        case "p": selectTool(.pen); return true
        case "l": selectTool(.line); return true
        case "a": selectTool(.arrow); return true
        case "r": selectTool(.rectangle); return true
        case "h": selectTool(.highlighter); return true
        case "e": selectTool(.eraser); return true
        default: return false
        }
    }

    /// ⌘ 组合键：⌘↩ / ⌘Z / ⇧⌘Z / ⌘C / ⌘S / ⌘W。
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            complete(with: .finish)
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "z":
            if event.modifierFlags.contains(.shift) {
                canvasView.redo()
            } else {
                canvasView.undo()
            }
            refreshToolbarState()
            return true
        case "c":
            complete(with: .copy)
            return true
        case "s":
            complete(with: .save)
            return true
        case "w":
            cancel()
            return true
        default:
            return false
        }
    }

    // MARK: 工具栏动作

    @objc func toolButtonTapped(_ sender: AnnotationToolButton) {
        focusWorkbench()
        selectTool(sender.tool)
    }

    @objc func colorSwatchTapped(_ sender: AnnotationColorSwatchButton) {
        focusWorkbench()
        selectColor(sender.swatchColor)
    }

    @objc func widthButtonTapped(_ sender: AnnotationWidthButton) {
        focusWorkbench()
        selectLineWidth(sender.dotWidth)
    }

    @objc func undoButtonTapped() {
        focusWorkbench()
        canvasView.undo()
        refreshToolbarState()
    }

    @objc func redoButtonTapped() {
        focusWorkbench()
        canvasView.redo()
        refreshToolbarState()
    }

    @objc func cancelButtonTapped() {
        cancel()
    }

    @objc func saveButtonTapped() {
        complete(with: .save)
    }

    @objc func copyButtonTapped() {
        complete(with: .copy)
    }

    @objc func finishButtonTapped() {
        complete(with: .finish)
    }

    // MARK: 离屏渲染自检

    /// 强制铺一套示例标注（供 `--render-ui` 截图）。
    func debugApplySampleAnnotations() {
        selectTool(.pen)
        selectColor(AnnotationPalette.defaultColor)
        selectLineWidth(AnnotationPalette.defaultLineWidth)
        canvasView.setDebugStrokes(AnnotationEditorController.makeSampleStrokes(displaySize: metrics.displaySize))
        refreshToolbarState()
    }

    /// 把窗口放到屏幕外并返回 contentView，供 `cacheDisplay` 离屏渲染。
    func debugPrepareForRendering(appearance: NSAppearance) -> NSView? {
        guard let window else { return nil }
        // 工作台固定深色：外观参数仅用于接口兼容，实际渲染始终深色
        _ = appearance
        window.appearance = NSAppearance(named: .darkAqua)
        toolbarView.setOffscreenRendering(true)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        workbenchView.needsLayout = true
        workbenchView.layoutSubtreeIfNeeded()
        workbenchView.needsDisplay = true
        canvasView.needsDisplay = true
        toolbarView.needsDisplay = true
        window.displayIfNeeded()
        return workbenchView
    }

    /// 开发自检：返回当前合成后的标注图（不关闭编辑器）。
    func debugCompositeImage() -> PinnedImage {
        canvasView.compositeImage() ?? sourceImage
    }

    // MARK: 尺寸 / 示例数据

    /// 计算画布显示尺寸与窗口尺寸：画布最大占屏幕可用区域 80%，窗口最小 820 宽。
    private static func makeMetrics(for image: PinnedImage) -> AnnotationEditorMetrics {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let source = image.pointSize
        let maxDisplayWidth = max(160, min(visible.width * 0.8, visible.width - 120))
        let maxDisplayHeight = max(120, min(visible.height * 0.8, visible.height - 220))
        let scale: CGFloat
        if source.width > 0, source.height > 0 {
            scale = min(1, maxDisplayWidth / source.width, maxDisplayHeight / source.height)
        } else {
            scale = 1
        }
        let displaySize = CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )

        var windowWidth = max(displaySize.width + AnnotationLayout.horizontalInset * 2, 820)
        var windowHeight = displaySize.height + AnnotationLayout.fixedVertical
        windowWidth = min(windowWidth, max(480, visible.width - 40))
        windowHeight = min(windowHeight, max(260, visible.height - 40))
        return AnnotationEditorMetrics(
            displaySize: displaySize,
            windowSize: CGSize(width: windowWidth.rounded(), height: windowHeight.rounded())
        )
    }

    /// 示例笔画：画笔曲线 / 直线 / 箭头 / 矩形 / 高亮各一条。
    private static func makeSampleStrokes(displaySize: CGSize) -> [AnnotationStroke] {
        let width = max(displaySize.width, 1)
        let height = max(displaySize.height, 1)
        let colors = AnnotationPalette.colors

        var penPoints: [CGPoint] = []
        for index in 0...28 {
            let t = CGFloat(index) / 28
            let wave = CGFloat(sin(Double(t * .pi * 3)))
            penPoints.append(CGPoint(
                x: width * (0.08 + 0.28 * t),
                y: height * (0.76 + 0.05 * wave)
            ))
        }

        return [
            AnnotationStroke(tool: .pen, points: penPoints, color: colors[0], lineWidth: 4),
            AnnotationStroke(
                tool: .line,
                points: [CGPoint(x: width * 0.08, y: height * 0.60), CGPoint(x: width * 0.34, y: height * 0.60)],
                color: colors[1],
                lineWidth: 4
            ),
            AnnotationStroke(
                tool: .arrow,
                points: [CGPoint(x: width * 0.58, y: height * 0.28), CGPoint(x: width * 0.84, y: height * 0.56)],
                color: colors[3],
                lineWidth: 4
            ),
            AnnotationStroke(
                tool: .rectangle,
                points: [CGPoint(x: width * 0.55, y: height * 0.68), CGPoint(x: width * 0.86, y: height * 0.84)],
                color: colors[4],
                lineWidth: 1.5
            ),
            AnnotationStroke(
                tool: .highlighter,
                points: [CGPoint(x: width * 0.12, y: height * 0.34), CGPoint(x: width * 0.50, y: height * 0.34)],
                color: colors[2],
                lineWidth: 14
            )
        ]
    }
}

// MARK: - 面板

/// 无边框、可成为 key 的标注面板。
@MainActor
final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 工作台根视图

/// 深色工作台：绘制圆角背景、承载工具栏 / 画布 / 底部提示，并统一处理键盘。
@MainActor
final class AnnotationWorkbenchView: NSView {
    weak var controller: AnnotationEditorController?

    private let canvas: AnnotationCanvasView
    private let toolbar: AnnotationToolbarView
    private let hintLabel: NSTextField

    init(frame frameRect: NSRect, canvas: AnnotationCanvasView, toolbar: AnnotationToolbarView) {
        self.canvas = canvas
        self.toolbar = toolbar
        self.hintLabel = NSTextField(labelWithString: "拖拽绘制 · P 画笔 · L 直线 · A 箭头 · R 矩形 · H 高亮 · E 橡皮擦 · ⌘Z 撤销 · Enter 完成")
        super.init(frame: frameRect)

        hintLabel.font = PSTheme.text(11)
        hintLabel.textColor = AnnotationEditorColors.hint
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.translatesAutoresizingMaskIntoConstraints = true
        hintLabel.isEditable = false
        hintLabel.isSelectable = false

        addSubview(toolbar)
        addSubview(canvas)
        addSubview(hintLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: AnnotationLayout.windowCornerRadius,
            yRadius: AnnotationLayout.windowCornerRadius
        )
        AnnotationEditorColors.background.setFill()
        path.fill()
        AnnotationEditorColors.backgroundBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 画布下方的柔和阴影（画布子视图会盖住填充，只露出四周光晕）
        guard canvas.bounds.width > 1, canvas.bounds.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor(white: 0.05, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: canvas.frame,
            xRadius: 8,
            yRadius: 8
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        toolbar.frame = NSRect(
            x: AnnotationLayout.horizontalInset,
            y: height - AnnotationLayout.topInset - AnnotationLayout.toolbarHeight,
            width: width - AnnotationLayout.horizontalInset * 2,
            height: AnnotationLayout.toolbarHeight
        )
        hintLabel.frame = NSRect(
            x: AnnotationLayout.horizontalInset,
            y: AnnotationLayout.bottomInset,
            width: width - AnnotationLayout.horizontalInset * 2,
            height: AnnotationLayout.hintHeight
        )
        canvas.frame = NSRect(
            x: ((width - canvas.displaySize.width) / 2).rounded(),
            y: AnnotationLayout.bottomInset + AnnotationLayout.hintHeight + AnnotationLayout.hintGap,
            width: canvas.displaySize.width,
            height: canvas.displaySize.height
        )
        needsDisplay = true
    }

    // 拖动深色背景移动窗口（画布与工具栏会自行消费事件）
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 工具栏

/// 44pt 高的磨砂玻璃工具栏：工具 / 6 色板 / 3 档粗细 / 撤销重做 / 取消保存复制完成。
@MainActor
final class AnnotationToolbarView: NSVisualEffectView {
    static let height = AnnotationLayout.toolbarHeight

    private let tintView = NSView()
    private let borderView = AnnotationToolbarBorderView()
    private var toolButtons: [AnnotationToolButton] = []
    private var swatches: [AnnotationColorSwatchButton] = []
    private var widthButtons: [AnnotationWidthButton] = []
    private var separators: [NSView] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var actionButtons: [PinButton] = []

    init(target: AnnotationEditorController) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = AnnotationToolbarView.tintColor(alpha: 0.20).cgColor
        addSubview(tintView)
        addSubview(borderView)

        buildItems(target: target)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 构建

    private func buildItems(target: AnnotationEditorController) {
        for tool in AnnotationStroke.Tool.allCases {
            let button = AnnotationToolButton(
                tool: tool,
                target: target,
                action: #selector(AnnotationEditorController.toolButtonTapped(_:))
            )
            addSubview(button)
            toolButtons.append(button)
        }

        for (index, color) in AnnotationPalette.colors.enumerated() {
            let swatch = AnnotationColorSwatchButton(
                color: color,
                accessibilityLabel: "标注颜色 \(AnnotationPalette.colorNames[index])",
                target: target,
                action: #selector(AnnotationEditorController.colorSwatchTapped(_:))
            )
            addSubview(swatch)
            swatches.append(swatch)
        }

        for width in AnnotationPalette.lineWidths {
            let button = AnnotationWidthButton(
                dotWidth: width,
                target: target,
                action: #selector(AnnotationEditorController.widthButtonTapped(_:))
            )
            addSubview(button)
            widthButtons.append(button)
        }

        for _ in 0..<3 {
            let separator = NSView()
            separator.wantsLayer = true
            separator.layer?.backgroundColor = AnnotationEditorColors.separator.cgColor
            addSubview(separator)
            separators.append(separator)
        }

        undoButton = makeSymbolButton(
            symbol: "arrow.uturn.backward",
            accessibilityLabel: "撤销 ⌘Z",
            target: target,
            action: #selector(AnnotationEditorController.undoButtonTapped)
        )
        redoButton = makeSymbolButton(
            symbol: "arrow.uturn.forward",
            accessibilityLabel: "重做 ⇧⌘Z",
            target: target,
            action: #selector(AnnotationEditorController.redoButtonTapped)
        )
        addSubview(undoButton)
        addSubview(redoButton)

        let cancel = PSTheme.makeButton(
            title: "取消", style: .text, target: target,
            action: #selector(AnnotationEditorController.cancelButtonTapped)
        )
        let save = PSTheme.makeButton(
            title: "保存", style: .secondary, target: target,
            action: #selector(AnnotationEditorController.saveButtonTapped)
        )
        let copy = PSTheme.makeButton(
            title: "复制", style: .secondary, target: target,
            action: #selector(AnnotationEditorController.copyButtonTapped)
        )
        let finish = PSTheme.makeButton(
            title: "完成", style: .primary, target: target,
            action: #selector(AnnotationEditorController.finishButtonTapped)
        )
        for button in [cancel, save, copy, finish] {
            button.contentInset = NSSize(width: 14, height: 7)
            button.buttonFont = PSTheme.text(13, weight: .semibold)
            addSubview(button)
            actionButtons.append(button)
        }

        setUndoRedo(canUndo: false, canRedo: false)
    }

    private func makeSymbolButton(
        symbol: String,
        accessibilityLabel: String,
        target: AnyObject,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(configuration) ?? image
            button.image?.isTemplate = true
        }
        button.contentTintColor = AnnotationEditorColors.toolIcon
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = target
        button.action = action
        return button
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        tintView.frame = bounds
        borderView.frame = bounds

        let height = bounds.height
        var x: CGFloat = 12

        // 工具组
        for button in toolButtons {
            button.frame = NSRect(x: x, y: (height - 28) / 2, width: 28, height: 28)
            x += 28 + 2
        }
        x += 6
        x = layoutSeparator(index: 0, at: x, height: height)

        // 色板
        for swatch in swatches {
            swatch.frame = NSRect(x: x, y: (height - 22) / 2, width: 22, height: 22)
            x += 22 + 2
        }
        x += 6
        x = layoutSeparator(index: 1, at: x, height: height)

        // 粗细
        for button in widthButtons {
            button.frame = NSRect(x: x, y: (height - 26) / 2, width: 26, height: 26)
            x += 26 + 2
        }
        x += 6
        x = layoutSeparator(index: 2, at: x, height: height)

        // 撤销 / 重做
        undoButton.frame = NSRect(x: x, y: (height - 28) / 2, width: 28, height: 28)
        x += 28 + 2
        redoButton.frame = NSRect(x: x, y: (height - 28) / 2, width: 28, height: 28)

        // 右侧动作按钮：取消 保存 复制 完成（右对齐）
        var rightEdge = bounds.width - 12
        for button in actionButtons.reversed() {
            let size = button.intrinsicContentSize
            let buttonHeight = min(max(size.height, 28), 34)
            button.frame = NSRect(
                x: rightEdge - size.width,
                y: ((height - buttonHeight) / 2).rounded(),
                width: size.width,
                height: buttonHeight
            )
            rightEdge -= size.width + 8
        }
    }

    private func layoutSeparator(index: Int, at x: CGFloat, height: CGFloat) -> CGFloat {
        let separator = separators[index]
        separator.frame = NSRect(x: x, y: (height - 22) / 2, width: 1, height: 22)
        return x + 1 + 10
    }

    // MARK: 状态

    func setSelectedTool(_ tool: AnnotationStroke.Tool) {
        for button in toolButtons {
            button.isSelected = button.tool == tool
        }
    }

    func setSelectedColor(_ color: NSColor) {
        for swatch in swatches {
            swatch.isSelected = AnnotationToolbarView.colorsMatch(swatch.swatchColor, color)
        }
    }

    func setSelectedLineWidth(_ width: CGFloat) {
        for button in widthButtons {
            button.isSelected = abs(button.dotWidth - width) < 0.01
        }
    }

    func setUndoRedo(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        undoButton.alphaValue = canUndo ? 1 : 0.3
        redoButton.isEnabled = canRedo
        redoButton.alphaValue = canRedo ? 1 : 0.3
    }

    /// 离屏渲染时 HUD 材质拿不到实时模糊，用更深的叠层模拟深色磨砂玻璃。
    func setOffscreenRendering(_ enabled: Bool) {
        let alpha: CGFloat = enabled ? 0.72 : 0.20
        tintView.layer?.backgroundColor = AnnotationToolbarView.tintColor(alpha: alpha).cgColor
        borderView.needsDisplay = true
    }

    private static func tintColor(alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: alpha)
    }

    private static func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let l = lhs.usingColorSpace(.sRGB), let r = rhs.usingColorSpace(.sRGB) else {
            return lhs.isEqual(rhs)
        }
        return abs(l.redComponent - r.redComponent) < 0.004
            && abs(l.greenComponent - r.greenComponent) < 0.004
            && abs(l.blueComponent - r.blueComponent) < 0.004
    }
}

/// 工具栏 1px 白色 12% 圆角描边（独立视图，离屏渲染也能画出来，不参与命中）。
@MainActor
final class AnnotationToolbarBorderView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 9.5,
            yRadius: 9.5
        )
        path.lineWidth = 1
        AnnotationEditorColors.border.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 工具按钮

/// 工具按钮：28×28，选中态 accentSoft 圆角底 + 橙色图标。
@MainActor
final class AnnotationToolButton: NSButton {
    let tool: AnnotationStroke.Tool

    private var isHovering = false
    private var isPressing = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet {
            contentTintColor = isSelected ? PSTheme.accent : AnnotationEditorColors.toolIcon
            needsDisplay = true
        }
    }

    init(tool: AnnotationStroke.Tool, target: AnyObject, action: Selector) {
        self.tool = tool
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true

        if let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            self.image = image.withSymbolConfiguration(configuration) ?? image
            self.image?.isTemplate = true
        }
        contentTintColor = AnnotationEditorColors.toolIcon
        toolTip = "\(tool.title)（\(tool.shortcut)）"
        setAccessibilityLabel(tool.title)
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressing = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            PSTheme.accentSoft.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        } else if isHovering || isPressing {
            let alpha: CGFloat = isPressing ? 0.16 : 0.10
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - 色板

/// 颜色圆点：选中态外圈 2pt 白环 + 中心点。
@MainActor
final class AnnotationColorSwatchButton: NSButton {
    let swatchColor: NSColor

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, accessibilityLabel: String, target: AnyObject, action: Selector) {
        self.swatchColor = color
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        title = ""
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        }

        let circleRect = bounds.insetBy(dx: 4, dy: 4)
        let circle = NSBezierPath(ovalIn: circleRect)
        swatchColor.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        guard isSelected else { return }
        // 2pt 白色外环
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor.white.setStroke()
        ring.lineWidth = 2
        ring.stroke()
        // 中心白点
        let dotRect = CGRect(x: bounds.midX - 1.6, y: bounds.midY - 1.6, width: 3.2, height: 3.2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

// MARK: - 粗细按钮

/// 粗细按钮：26×26，圆点大小代表 2 / 4 / 8pt。
@MainActor
final class AnnotationWidthButton: NSButton {
    let dotWidth: CGFloat

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(dotWidth: CGFloat, target: AnyObject, action: Selector) {
        self.dotWidth = dotWidth
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        title = ""
        toolTip = "粗细 \(Int(dotWidth))pt"
        setAccessibilityLabel("粗细 \(Int(dotWidth))pt")
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // 选中态：比 accentSoft 再亮一点的橙色圆底，让白色粗细点对比更清楚
            PSTheme.accent.withAlphaComponent(0.26).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        }

        let diameter = max(dotWidth, 2)
        let dotRect = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        // 选中态用信号橙点（设计系统里橙色代表选中），未选中为 62% 白点
        (isSelected ? PSTheme.accent : NSColor.white.withAlphaComponent(0.62)).setFill()
        dot.fill()
    }
}
