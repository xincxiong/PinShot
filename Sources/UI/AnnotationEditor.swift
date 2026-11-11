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

/// 标注编辑器打开时自动 OCR 的状态，用于底部提示按钮。
enum OCRAutoStatus {
    case idle
    case recognizing
    case ready(Int)
    case empty
    case failed
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
    private var moreToolsPopover: NSPopover?
    private var moreToolsController: AnnotationMoreToolsViewController?
    private var finished = false
    private var ocrRunning = false
    private var ocrResult: TextRecognitionResult?
    private var ocrPresentWhenReady = false
    /// 进入取色 / 测量等瞬时工具之前的工具，Esc 退出时回到它
    private var toolBeforeTransient: AnnotationStroke.Tool = .pen

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
        canvas.onColorPicked = { [weak self] hex, _ in
            // 取色只做临时提示，不生成笔画、不参与导出
            self?.workbenchView.showTemporaryHint("已复制颜色 \(hex)")
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
        startAutomaticOCR()
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
        // 未提交的文字先落笔，再合成原生像素图
        canvasView.endTextEditing()
        // 先把当前笔画合成成原生像素图，再关闭窗口
        let annotated = canvasView.compositeImage() ?? sourceImage
        finish(.completed(annotated, action: action))
    }

    // MARK: 选择状态

    func selectTool(_ tool: AnnotationStroke.Tool) {
        let previous = canvasView.tool
        // 记录进入取色 / 测量 / 放大镜前使用的工具，退出瞬时工具时恢复
        if previous != tool, !previous.isTransient {
            toolBeforeTransient = previous
        }
        canvasView.tool = tool
        toolbarView.setSelectedTool(tool)
        workbenchView.updateHint(for: tool)
    }

    /// 取色 / 测量 / 放大镜等瞬时工具按 Esc 时优先退出到上一个工具；返回是否消费了 Esc。
    @discardableResult
    private func exitTransientToolIfNeeded() -> Bool {
        guard canvasView.tool.isTransient else { return false }
        selectTool(toolBeforeTransient)
        return true
    }

    func selectColor(_ color: NSColor) {
        canvasView.strokeColor = color
        toolbarView.setSelectedColor(color)
    }

    func selectLineWidth(_ width: CGFloat) {
        canvasView.lineWidth = width
        toolbarView.setSelectedLineWidth(width)
    }

    func selectBlurStyle(_ style: AnnotationStroke.BlurStyle) {
        canvasView.blurStyle = style
        refreshToolbarState()
    }

    func selectSpotlightStyle(_ style: AnnotationStroke.SpotlightStyle) {
        canvasView.spotlightStyle = style
        refreshToolbarState()
    }

    /// 应用背景板设置：重排预览尺寸（必要时等比缩小画布避免裁切）并刷新弹窗选中态。
    func setBackdrop(_ settings: AnnotationBackdrop) {
        canvasView.endTextEditing()
        canvasView.backdrop = settings
        applyBackdropLayout()
        refreshToolbarState()
    }

    /// 背景板开关 / 内边距变化后重新计算画布显示尺寸。
    private func applyBackdropLayout() {
        let base = metrics.displaySize
        let paddingRatio = canvasView.backdrop.isEnabled ? canvasView.backdrop.padding.ratio : 0
        var display = base
        if paddingRatio > 0 {
            // 预留 24pt 给卡片阴影 / 描边，避免贴边被窗口裁掉
            let available = CGSize(
                width: max(120, metrics.windowSize.width - AnnotationLayout.horizontalInset * 2 - 24),
                height: max(120, metrics.windowSize.height - AnnotationLayout.fixedVertical - 24)
            )
            let scale = min(
                1,
                available.width / (base.width * (1 + paddingRatio * 2)),
                available.height / (base.height * (1 + paddingRatio * 2))
            )
            display = CGSize(
                width: max(80, (base.width * scale).rounded()),
                height: max(80, (base.height * scale).rounded())
            )
        }
        canvasView.setDisplaySize(display)
        workbenchView.needsLayout = true
        workbenchView.layoutSubtreeIfNeeded()
        workbenchView.needsDisplay = true
        canvasView.needsDisplay = true
    }

    private func refreshToolbarState() {
        toolbarView.setSelectedTool(canvasView.tool)
        toolbarView.setSelectedColor(canvasView.strokeColor)
        toolbarView.setSelectedLineWidth(canvasView.lineWidth)
        toolbarView.setUndoRedo(canUndo: canvasView.canUndo, canRedo: canvasView.canRedo)
        moreToolsController?.updateSelection(
            tool: canvasView.tool,
            blurStyle: canvasView.blurStyle,
            spotlightStyle: canvasView.spotlightStyle,
            backdrop: canvasView.backdrop
        )
    }

    private func focusWorkbench() {
        canvasView?.endTextEditing()
        window?.makeFirstResponder(workbenchView)
    }

    // MARK: 键盘

    /// 普通按键：Esc / Return / 工具快捷键。
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            // 取色 / 测量等瞬时工具先退出到上一个工具，再按一次才取消编辑器
            if exitTransientToolIfNeeded() { return true }
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
        case "t": selectTool(.text); return true
        case "n": selectTool(.step); return true
        case "b": selectTool(.blur); return true
        case "g": selectTool(.spotlight); return true
        case "i": selectTool(.eyedropper); return true
        case "m": selectTool(.ruler); return true
        case "z": selectTool(.loupe); return true
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
            if event.modifierFlags.contains(.shift) {
                shareCurrentImage(from: workbenchView)
            } else {
                complete(with: .save)
            }
            return true
        case "w":
            cancel()
            return true
        case "t":
            ocrButtonTapped()
            return true
        default:
            return false
        }
    }

    /// 分享当前合成图（含标注与背景板）。
    func shareCurrentImage(from view: NSView) {
        let image = canvasView.compositeImage() ?? sourceImage
        ShareService.share(pinnedImage: image, from: view, preferredEdge: .maxY)
    }

    // MARK: OCR

    /// 打开标注编辑器时在后台自动识别一次，结果实时显示在底部按钮上。
    private func startAutomaticOCR() {
        guard !ocrRunning, ocrResult == nil else { return }
        ocrRunning = true
        workbenchView.setOCRStatus(.recognizing)
        TextRecognizer.recognize(cgImage: sourceImage.cgImage) { [weak self] result in
            guard let self else { return }
            self.ocrRunning = false
            self.ocrResult = result
            if result.errorMessage != nil {
                self.workbenchView.setOCRStatus(.failed)
            } else if result.isEmpty {
                self.workbenchView.setOCRStatus(.empty)
            } else {
                self.workbenchView.setOCRStatus(.ready(result.text.count))
            }
            if self.ocrPresentWhenReady {
                self.ocrPresentWhenReady = false
                OCRPanelController.shared.present(image: self.sourceImage, title: "识别文字")
            }
        }
    }

    /// 点击底部「识别文字」/ ⌘T：自动识别还未完成时等它完成后再弹窗，避免重复 OCR。
    func ocrButtonTapped() {
        focusWorkbench()
        if ocrRunning {
            ocrPresentWhenReady = true
            return
        }
        if let result = ocrResult, result.errorMessage == nil, !result.isEmpty {
            OCRPanelController.shared.present(
                text: result.text,
                title: "识别文字"
            )
            return
        }
        if ocrResult == nil {
            // 自动 OCR 没来得及启动（例如离屏渲染模式），按需启动并弹窗。
            ocrPresentWhenReady = true
            startAutomaticOCR()
            return
        }
        OCRPanelController.shared.present(image: sourceImage, title: "识别文字")
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

    // MARK: 「更多工具」弹窗

    /// 工具栏 ▸ 更多工具按钮：弹出文字 / 序号 / 模糊 / 聚光灯 / 取色 / 测量
    @objc func moreToolsButtonTapped(_ sender: NSButton) {
        let popover = ensureMoreToolsPopover()
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        canvasView.endTextEditing()
        moreToolsController?.updateSelection(
            tool: canvasView.tool,
            blurStyle: canvasView.blurStyle,
            spotlightStyle: canvasView.spotlightStyle,
            backdrop: canvasView.backdrop
        )
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func ensureMoreToolsPopover() -> NSPopover {
        if let moreToolsPopover { return moreToolsPopover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = AnnotationMoreToolsViewController()
        content.onSelectTool = { [weak self] tool in
            guard let self else { return }
            self.selectTool(tool)
            self.moreToolsPopover?.performClose(nil)
            self.focusWorkbench()
        }
        content.onBlurStyleChanged = { [weak self] style in
            guard let self else { return }
            self.selectBlurStyle(style)
            self.focusWorkbench()
        }
        content.onSpotlightStyleChanged = { [weak self] style in
            guard let self else { return }
            self.selectSpotlightStyle(style)
            self.focusWorkbench()
        }
        content.onBackdropChanged = { [weak self] settings in
            guard let self else { return }
            self.setBackdrop(settings)
        }
        popover.contentViewController = content
        // 先完成 loadView，preferredContentSize 才是有效值；否则弹窗会以 0 尺寸显示
        content.loadViewIfNeeded()
        popover.contentSize = content.preferredContentSize
        moreToolsPopover = popover
        moreToolsController = content
        return popover
    }

    // MARK: 离屏渲染自检

    /// 强制铺一套示例标注（供 `--render-ui` 截图）。
    func debugApplySampleAnnotations() {
        selectTool(.pen)
        selectColor(AnnotationPalette.defaultColor)
        selectLineWidth(AnnotationPalette.defaultLineWidth)
        // 背景板样例：纸白 + 中等内边距 + 圆角 / 阴影，供 `--render-ui` 目检
        setBackdrop(AnnotationBackdrop(
            isEnabled: true,
            preset: .paper,
            padding: .medium,
            rounded: true,
            shadow: true
        ))
        // 背景板会缩小画布显示区域，示例笔画 / 测量按最终显示尺寸生成
        let displaySize = canvasView.displaySize
        canvasView.setDebugStrokes(AnnotationEditorController.makeSampleStrokes(displaySize: displaySize))
        canvasView.debugSetRulerMeasurement(
            start: CGPoint(x: displaySize.width * 0.18, y: displaySize.height * 0.40),
            end: CGPoint(x: displaySize.width * 0.62, y: displaySize.height * 0.68)
        )
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

    /// 示例笔画：画笔曲线 / 直线 / 箭头 / 矩形 / 高亮 + 扩展工具（模糊 / 文字 / 序号 / 聚光灯）。
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
            ),
            // 扩展工具：马赛克 / 文字 / 序号
            // 马赛克放在右侧终端窗口与壁纸交界处（有灰条 / 色块，离屏截图里能看出块状效果）
            AnnotationStroke(
                tool: .blur,
                points: [CGPoint(x: width * 0.86, y: height * 0.45), CGPoint(x: width * 0.995, y: height * 0.86)],
                color: colors[0],
                lineWidth: 8,
                blurStyle: .pixelate
            ),
            AnnotationStroke(
                tool: .text,
                points: [CGPoint(x: width * 0.08, y: height * 0.16)],
                color: colors[5],
                lineWidth: 26,
                text: "PinShot 标注"
            ),
            AnnotationStroke(
                tool: .step,
                points: [CGPoint(x: width * 0.66, y: height * 0.50)],
                color: colors[1],
                lineWidth: 8,
                stepNumber: 1
            ),
            AnnotationStroke(
                tool: .step,
                points: [CGPoint(x: width * 0.74, y: height * 0.40)],
                color: colors[1],
                lineWidth: 8,
                stepNumber: 2
            ),
            // 聚光灯：覆盖几乎整幅图，只在四边压暗（圆角可见），不遮挡其他示例笔画
            AnnotationStroke(
                tool: .spotlight,
                points: [
                    CGPoint(x: width * 0.035, y: height * 0.035),
                    CGPoint(x: width * 0.965, y: height * 0.965)
                ],
                color: colors[5],
                lineWidth: 4,
                spotlightStyle: .dark
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
    /// 默认底部提示：压缩后的全量快捷键说明（宽度不够时尾部省略）
    private static let defaultHint = "P 画笔 · L 直线 · A 箭头 · R 矩形 · H 高亮 · E 橡皮 · T 文字 · N 序号 · B 模糊 · G 聚光灯 · I 取色 · M 测量 · Z 放大镜 · ⌘Z 撤销 · ⏎ 完成"

    weak var controller: AnnotationEditorController?

    private let canvas: AnnotationCanvasView
    private let toolbar: AnnotationToolbarView
    private let hintLabel: NSTextField
    private let ocrButton = NSButton()
    private let shareButton = NSButton()

    /// 当前工具 / 临时提示的失效令牌：避免旧 toast 的延时恢复覆盖新提示
    private var currentTool: AnnotationStroke.Tool = .pen
    private var hintToken = 0

    init(frame frameRect: NSRect, canvas: AnnotationCanvasView, toolbar: AnnotationToolbarView) {
        self.canvas = canvas
        self.toolbar = toolbar
        self.hintLabel = NSTextField(labelWithString: Self.defaultHint)
        super.init(frame: frameRect)

        hintLabel.font = PSTheme.text(10.5)
        hintLabel.textColor = AnnotationEditorColors.hint
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.translatesAutoresizingMaskIntoConstraints = true
        hintLabel.isEditable = false
        hintLabel.isSelectable = false

        ocrButton.isBordered = false
        ocrButton.bezelStyle = .regularSquare
        ocrButton.focusRingType = .none
        ocrButton.font = PSTheme.text(11, weight: .medium)
        ocrButton.alignment = .right
        setOCRButtonTitle("识别文字 ⌘T", color: PSTheme.accent)
        ocrButton.target = self
        ocrButton.action = #selector(ocrTapped)
        ocrButton.toolTip = "识别截图中的文字（⌘T）"
        ocrButton.setAccessibilityLabel("识别截图中的文字")

        shareButton.isBordered = false
        shareButton.bezelStyle = .regularSquare
        shareButton.focusRingType = .none
        if let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "分享截图") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            shareButton.image = image.withSymbolConfiguration(configuration) ?? image
            shareButton.image?.isTemplate = true
        }
        shareButton.contentTintColor = PSTheme.accent
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        shareButton.toolTip = "分享截图（⇧⌘S）"
        shareButton.setAccessibilityLabel("分享截图")

        addSubview(toolbar)
        addSubview(canvas)
        addSubview(hintLabel)
        addSubview(ocrButton)
        addSubview(shareButton)
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

        guard canvas.bounds.width > 1, canvas.bounds.height > 1 else { return }
        if canvas.backdrop.isEnabled {
            drawBackdropPreview(in: canvas.frame)
        } else {
            // 画布下方的柔和阴影（画布子视图会盖住填充，只露出四周光晕）
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
    }

    /// 背景板预览：图片外围绘制预设底色卡片 + 圆角 + 柔和阴影（导出时按像素比例合成同样的效果）。
    private func drawBackdropPreview(in imageFrame: NSRect) {
        let padding = canvas.backdropPaddingDisplay
        guard padding > 0 else { return }
        let settings = canvas.backdrop
        let cardRect = imageFrame.insetBy(dx: -padding, dy: -padding)
        let cardRadius = canvas.backdropCardCornerRadius
        let cardPath = NSBezierPath(
            roundedRect: cardRect,
            xRadius: cardRadius,
            yRadius: cardRadius
        )
        settings.preset.color.setFill()
        cardPath.fill()
        let borderColor = settings.preset.isLight
            ? NSColor.black.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.10)
        borderColor.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        guard settings.shadow else { return }
        // 用与卡片相同的底色填充图片圆角矩形：填充本身不可见，只留下柔和阴影
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(8, padding * 0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -max(2, padding * 0.10))
        shadow.set()
        settings.preset.color.setFill()
        NSBezierPath(
            roundedRect: imageFrame,
            xRadius: canvas.imageCornerRadius,
            yRadius: canvas.imageCornerRadius
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
        let ocrWidth: CGFloat = 122
        let shareWidth: CGFloat = 24
        hintLabel.frame = NSRect(
            x: AnnotationLayout.horizontalInset,
            y: AnnotationLayout.bottomInset,
            width: max(80, width - AnnotationLayout.horizontalInset * 2 - ocrWidth - shareWidth - 20),
            height: AnnotationLayout.hintHeight
        )
        shareButton.frame = NSRect(
            x: width - AnnotationLayout.horizontalInset - shareWidth,
            y: AnnotationLayout.bottomInset - 2,
            width: shareWidth,
            height: 20
        )
        ocrButton.frame = NSRect(
            x: shareButton.frame.minX - 8 - ocrWidth,
            y: AnnotationLayout.bottomInset - 2,
            width: ocrWidth,
            height: 20
        )
        // 背景板开启时按「图片 + 内边距」的卡片整体居中，关闭时卡片即图片
        let padding = canvas.backdropPaddingDisplay
        let regionBottom = AnnotationLayout.bottomInset + AnnotationLayout.hintHeight + AnnotationLayout.hintGap
        let regionTop = height - AnnotationLayout.topInset - AnnotationLayout.toolbarHeight - AnnotationLayout.toolbarToCanvasGap
        let cardWidth = canvas.displaySize.width + padding * 2
        let cardHeight = canvas.displaySize.height + padding * 2
        let cardX = ((width - cardWidth) / 2).rounded()
        let cardY = (regionBottom + max(0, (regionTop - regionBottom - cardHeight) / 2)).rounded()
        canvas.frame = NSRect(
            x: cardX + padding,
            y: cardY + padding,
            width: canvas.displaySize.width,
            height: canvas.displaySize.height
        )
        needsDisplay = true
    }

    // 拖动深色背景移动窗口（画布与工具栏会自行消费事件）
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func ocrTapped() {
        controller?.ocrButtonTapped()
    }

    @objc private func shareTapped() {
        controller?.shareCurrentImage(from: self)
    }

    // MARK: 底部提示

    /// 切换工具时更新底部提示：瞬时工具给操作说明，其余显示压缩后的全量快捷键。
    func updateHint(for tool: AnnotationStroke.Tool) {
        currentTool = tool
        hintToken += 1
        let text: String
        switch tool {
        case .spotlight:
            text = "拖拽框选聚光区域：区域外压暗、内部保持原亮度 · G"
        case .eyedropper:
            text = "点击画布任意位置取色，复制 #RRGGBB 到剪贴板 · Esc 退出"
        case .ruler:
            text = "拖拽测量宽 × 高与斜线长度（截图原生像素）· 切换工具清除"
        case .loupe:
            text = "移动鼠标查看像素放大与对白/对黑对比度，点击复制 #RRGGBB · Esc 退出"
        default:
            text = Self.defaultHint
        }
        setHint(text, color: AnnotationEditorColors.hint)
    }

    /// 临时提示（例如取色结果的色值）：显示一段时间后恢复当前工具的提示。
    func showTemporaryHint(_ text: String, duration: TimeInterval = 1.8) {
        hintToken += 1
        let token = hintToken
        setHint(text, color: PSTheme.accent)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.hintToken == token else { return }
            self.updateHint(for: self.currentTool)
        }
    }

    private func setHint(_ text: String, color: NSColor) {
        hintLabel.stringValue = text
        hintLabel.textColor = color
    }

    /// 自动识别状态：更新底部右侧的 OCR 按钮。
    func setOCRStatus(_ status: OCRAutoStatus) {
        switch status {
        case .idle:
            setOCRButtonTitle("识别文字 ⌘T", color: PSTheme.accent)
        case .recognizing:
            setOCRButtonTitle("识别中…", color: AnnotationEditorColors.hint)
        case .ready(let characters):
            setOCRButtonTitle("文字 \(characters) 字 · ⌘T", color: PSTheme.accent)
        case .empty:
            setOCRButtonTitle("未识别到文字", color: AnnotationEditorColors.hint)
        case .failed:
            setOCRButtonTitle("识别失败 · 重试", color: NSColor.systemRed.withAlphaComponent(0.9))
        }
    }

    private func setOCRButtonTitle(_ title: String, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.text(11, weight: .medium),
            .foregroundColor: color
        ]
        ocrButton.attributedTitle = NSAttributedString(string: title, attributes: attributes)
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
    private var moreToolsButton: NSButton!
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
        for tool in AnnotationStroke.Tool.primaryTools {
            let button = AnnotationToolButton(
                tool: tool,
                target: target,
                action: #selector(AnnotationEditorController.toolButtonTapped(_:))
            )
            addSubview(button)
            toolButtons.append(button)
        }

        // 「更多工具」：文字 / 序号 / 模糊 / 聚光灯 / 取色 / 测量（NSPopover）
        moreToolsButton = makeSymbolButton(
            symbol: "ellipsis.circle",
            accessibilityLabel: "更多工具：文字 / 序号 / 模糊 / 聚光灯 / 取色 / 测量 / 放大镜",
            target: target,
            action: #selector(AnnotationEditorController.moreToolsButtonTapped(_:))
        )
        moreToolsButton.toolTip = "更多工具（T 文字 · N 序号 · B 模糊 · G 聚光灯 · I 取色 · M 测量 · Z 放大镜）"
        moreToolsButton.setAccessibilityLabel("更多工具")
        addSubview(moreToolsButton)

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
        // 更多工具按钮（与主工具同尺寸，扩展工具选中时图标变橙）
        moreToolsButton.frame = NSRect(x: x, y: (height - 28) / 2, width: 28, height: 28)
        x += 28 + 2
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
        // 扩展工具（文字 / 序号 / 模糊）用橙色图标提示「更多工具」里当前有选中项
        moreToolsButton?.contentTintColor = tool.isExtended
            ? PSTheme.accent
            : AnnotationEditorColors.toolIcon
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

// MARK: - 「更多工具」弹窗

/// 「更多工具」NSPopover 的内容：文字 / 序号 / 模糊 / 聚光灯 / 取色 / 测量 / 放大镜 七行，
/// 下方再给出模糊样式、聚光灯样式与背景板设置。
@MainActor
final class AnnotationMoreToolsViewController: NSViewController {
    /// 弹窗固定尺寸（与 loadView 里的容器一致）
    static let preferredSize = NSSize(width: 236, height: 484)

    var onSelectTool: ((AnnotationStroke.Tool) -> Void)?
    var onBlurStyleChanged: ((AnnotationStroke.BlurStyle) -> Void)?
    var onSpotlightStyleChanged: ((AnnotationStroke.SpotlightStyle) -> Void)?
    var onBackdropChanged: ((AnnotationBackdrop) -> Void)?

    private static let blurStyles: [AnnotationStroke.BlurStyle] = [.pixelate, .gaussian]
    private static let spotlightStyles: [AnnotationStroke.SpotlightStyle] = [.dark, .light]

    private var backdrop = AnnotationBackdrop()

    private var rows: [AnnotationPopoverToolRowButton] = []
    private var blurStyleButtons: [AnnotationStyleOptionButton] = []
    private var spotlightStyleButtons: [AnnotationStyleOptionButton] = []
    private var backdropColorButtons: [AnnotationColorSwatchButton] = []
    private var backdropPaddingButtons: [AnnotationStyleOptionButton] = []
    private var roundedButton: AnnotationStyleOptionButton!
    private var shadowButton: AnnotationStyleOptionButton!
    private let blurStyleLabel = NSTextField(labelWithString: "模糊样式")
    private let spotlightStyleLabel = NSTextField(labelWithString: "聚光灯")
    private let backdropLabel = NSTextField(labelWithString: "背景板")
    private let separator = NSView()
    private let backdropSeparator = NSView()
    private var backdropSwitch: PinSwitch!

    override func loadView() {
        let size = Self.preferredSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view = container
        preferredContentSize = size

        // 7 行工具：自上而下排列（顶部留 8、行高 30、行距 2）
        var rowY = size.height - 8 - 30
        for tool in AnnotationStroke.Tool.extendedTools {
            let row = AnnotationPopoverToolRowButton(
                tool: tool,
                target: self,
                action: #selector(rowTapped(_:))
            )
            row.frame = NSRect(x: 8, y: rowY, width: size.width - 16, height: 30)
            container.addSubview(row)
            rows.append(row)
            rowY -= 32
        }

        configureSeparator(separator)
        separator.frame = NSRect(x: 10, y: 246, width: size.width - 20, height: 1)
        container.addSubview(separator)

        configureStyleLabel(blurStyleLabel)
        blurStyleLabel.frame = NSRect(x: 10, y: 224, width: 120, height: 14)
        container.addSubview(blurStyleLabel)

        configureStyleLabel(spotlightStyleLabel)
        spotlightStyleLabel.frame = NSRect(x: 10, y: 168, width: 120, height: 14)
        container.addSubview(spotlightStyleLabel)

        let gap: CGFloat = 6
        let optionWidth = (size.width - 16 - gap) / 2
        for (index, style) in Self.blurStyles.enumerated() {
            let button = AnnotationStyleOptionButton(
                title: style.title,
                tag: style.rawValue,
                target: self,
                action: #selector(blurStyleButtonTapped(_:))
            )
            button.frame = NSRect(
                x: 8 + CGFloat(index) * (optionWidth + gap),
                y: 194,
                width: optionWidth,
                height: 24
            )
            container.addSubview(button)
            blurStyleButtons.append(button)
        }
        for (index, style) in Self.spotlightStyles.enumerated() {
            let button = AnnotationStyleOptionButton(
                title: style.title,
                tag: style.rawValue,
                target: self,
                action: #selector(spotlightStyleButtonTapped(_:))
            )
            button.frame = NSRect(
                x: 8 + CGFloat(index) * (optionWidth + gap),
                y: 138,
                width: optionWidth,
                height: 24
            )
            container.addSubview(button)
            spotlightStyleButtons.append(button)
        }

        // 背景板：开关 + 4 底色 + 3 档内边距 + 圆角 / 阴影
        configureSeparator(backdropSeparator)
        backdropSeparator.frame = NSRect(x: 10, y: 126, width: size.width - 20, height: 1)
        container.addSubview(backdropSeparator)

        configureStyleLabel(backdropLabel)
        backdropLabel.frame = NSRect(x: 10, y: 100, width: 120, height: 14)
        container.addSubview(backdropLabel)

        let enabledSwitch = PinSwitch(isOn: backdrop.isEnabled)
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = true
        enabledSwitch.setLabel("背景板开关")
        enabledSwitch.frame = NSRect(x: size.width - 10 - 38, y: 96, width: 38, height: 22)
        enabledSwitch.target = self
        enabledSwitch.action = #selector(backdropSwitchChanged(_:))
        container.addSubview(enabledSwitch)
        enabledSwitch.layout()
        backdropSwitch = enabledSwitch

        for (index, preset) in AnnotationBackdrop.Preset.allCases.enumerated() {
            let swatch = AnnotationColorSwatchButton(
                color: preset.color,
                accessibilityLabel: "背景板\(preset.title) \(preset.hex)",
                target: self,
                action: #selector(backdropColorTapped(_:))
            )
            swatch.tag = preset.rawValue
            swatch.frame = NSRect(x: 12 + CGFloat(index) * 32, y: 68, width: 22, height: 22)
            container.addSubview(swatch)
            backdropColorButtons.append(swatch)
        }

        let paddingWidth = (size.width - 16 - gap * 2) / 3
        for (index, padding) in AnnotationBackdrop.Padding.allCases.enumerated() {
            let button = AnnotationStyleOptionButton(
                title: padding.title,
                tag: padding.rawValue,
                target: self,
                action: #selector(backdropPaddingTapped(_:))
            )
            button.toolTip = padding.caption
            button.setAccessibilityLabel(padding.caption)
            button.frame = NSRect(
                x: 8 + CGFloat(index) * (paddingWidth + gap),
                y: 38,
                width: paddingWidth,
                height: 24
            )
            container.addSubview(button)
            backdropPaddingButtons.append(button)
        }

        let rounded = AnnotationStyleOptionButton(
            title: "圆角",
            tag: 0,
            target: self,
            action: #selector(roundedTapped(_:))
        )
        rounded.toolTip = "图片与背景板圆角"
        rounded.frame = NSRect(x: 8, y: 8, width: optionWidth, height: 24)
        container.addSubview(rounded)
        roundedButton = rounded

        let shadow = AnnotationStyleOptionButton(
            title: "阴影",
            tag: 0,
            target: self,
            action: #selector(shadowTapped(_:))
        )
        shadow.toolTip = "图片柔和阴影"
        shadow.frame = NSRect(x: 8 + optionWidth + gap, y: 8, width: optionWidth, height: 24)
        container.addSubview(shadow)
        shadowButton = shadow
    }

    private func configureSeparator(_ separator: NSView) {
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    private func configureStyleLabel(_ label: NSTextField) {
        label.font = PSTheme.text(11)
        label.textColor = NSColor.white.withAlphaComponent(0.45)
        label.isEditable = false
        label.isSelectable = false
    }

    /// 同步当前工具 / 模糊样式 / 聚光灯样式 / 背景板的高亮状态；相关标签同步变橙。
    func updateSelection(
        tool: AnnotationStroke.Tool,
        blurStyle: AnnotationStroke.BlurStyle,
        spotlightStyle: AnnotationStroke.SpotlightStyle,
        backdrop: AnnotationBackdrop
    ) {
        self.backdrop = backdrop
        for row in rows {
            row.isSelected = row.tool == tool
        }
        for button in blurStyleButtons {
            button.isSelected = button.tag == blurStyle.rawValue
        }
        for button in spotlightStyleButtons {
            button.isSelected = button.tag == spotlightStyle.rawValue
        }
        blurStyleLabel.textColor = tool == .blur
            ? PSTheme.accent
            : NSColor.white.withAlphaComponent(0.45)
        spotlightStyleLabel.textColor = tool == .spotlight
            ? PSTheme.accent
            : NSColor.white.withAlphaComponent(0.45)

        // 背景板
        backdropSwitch.setOn(backdrop.isEnabled, animated: false)
        backdropLabel.textColor = backdrop.isEnabled
            ? PSTheme.accent
            : NSColor.white.withAlphaComponent(0.45)
        for button in backdropColorButtons {
            button.isSelected = button.tag == backdrop.preset.rawValue
        }
        for button in backdropPaddingButtons {
            button.isSelected = button.tag == backdrop.padding.rawValue
        }
        roundedButton.isSelected = backdrop.rounded
        shadowButton.isSelected = backdrop.shadow
        // 背景板关闭时弱化细节控件，避免误以为已生效
        let controlsAlpha: CGFloat = backdrop.isEnabled ? 1 : 0.55
        for view in backdropColorButtons { view.alphaValue = controlsAlpha }
        for view in backdropPaddingButtons { view.alphaValue = controlsAlpha }
        roundedButton.alphaValue = controlsAlpha
        shadowButton.alphaValue = controlsAlpha
    }

    @objc private func rowTapped(_ sender: AnnotationPopoverToolRowButton) {
        onSelectTool?(sender.tool)
    }

    @objc private func blurStyleButtonTapped(_ sender: AnnotationStyleOptionButton) {
        guard let style = AnnotationStroke.BlurStyle(rawValue: sender.tag) else { return }
        onBlurStyleChanged?(style)
    }

    @objc private func spotlightStyleButtonTapped(_ sender: AnnotationStyleOptionButton) {
        guard let style = AnnotationStroke.SpotlightStyle(rawValue: sender.tag) else { return }
        onSpotlightStyleChanged?(style)
    }

    @objc private func backdropSwitchChanged(_ sender: PinSwitch) {
        var settings = backdrop
        settings.isEnabled = sender.isOn
        backdrop = settings
        onBackdropChanged?(settings)
    }

    @objc private func backdropColorTapped(_ sender: AnnotationColorSwatchButton) {
        guard let preset = AnnotationBackdrop.Preset(rawValue: sender.tag) else { return }
        var settings = backdrop
        settings.preset = preset
        backdrop = settings
        onBackdropChanged?(settings)
    }

    @objc private func backdropPaddingTapped(_ sender: AnnotationStyleOptionButton) {
        guard let padding = AnnotationBackdrop.Padding(rawValue: sender.tag) else { return }
        var settings = backdrop
        settings.padding = padding
        backdrop = settings
        onBackdropChanged?(settings)
    }

    @objc private func roundedTapped(_ sender: AnnotationStyleOptionButton) {
        var settings = backdrop
        settings.rounded.toggle()
        backdrop = settings
        onBackdropChanged?(settings)
    }

    @objc private func shadowTapped(_ sender: AnnotationStyleOptionButton) {
        var settings = backdrop
        settings.shadow.toggle()
        backdrop = settings
        onBackdropChanged?(settings)
    }
}

/// 「更多工具」弹窗里的样式选项（模糊样式 / 聚光灯样式），选中态橙色。
/// 用 `tag` 承载样式 rawValue，由弹窗在回调里换算成具体样式。
@MainActor
final class AnnotationStyleOptionButton: NSButton {
    private let optionTitle: String

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet {
            updateTitle()
            needsDisplay = true
        }
    }

    init(title: String, tag: Int, target: AnyObject, action: Selector) {
        self.optionTitle = title
        super.init(frame: .zero)
        self.tag = tag
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        toolTip = title
        setAccessibilityLabel(title)
        self.target = target
        self.action = action
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    private func updateTitle() {
        attributedTitle = NSAttributedString(
            string: optionTitle,
            attributes: [
                .font: PSTheme.text(11, weight: .medium),
                .foregroundColor: isSelected ? PSTheme.accent : NSColor.white.withAlphaComponent(0.62)
            ]
        )
    }

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
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isSelected {
            PSTheme.accentSoft.setFill()
            rounded.fill()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.08).setFill()
            rounded.fill()
        }
        NSColor.white.withAlphaComponent(isSelected ? 0.16 : 0.10).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()
        super.draw(dirtyRect)
    }
}

/// 「更多工具」弹窗里的一行：图标 + 名称 + 快捷键，选中时橙色浅底。
@MainActor
final class AnnotationPopoverToolRowButton: NSButton {
    let tool: AnnotationStroke.Tool

    private let shortcutLabel = NSTextField(labelWithString: "")
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(tool: AnnotationStroke.Tool, target: AnyObject, action: Selector) {
        self.tool = tool
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        contentTintColor = NSColor.white.withAlphaComponent(0.82)

        if let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            self.image = image.withSymbolConfiguration(configuration) ?? image
            self.image?.isTemplate = true
        }
        attributedTitle = NSAttributedString(
            string: "   " + tool.title,
            attributes: [
                .font: PSTheme.text(12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
        )
        toolTip = "\(tool.title)（\(tool.shortcut)）"
        setAccessibilityLabel(tool.title)

        shortcutLabel.stringValue = tool.shortcut
        shortcutLabel.font = PSTheme.mono(10)
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        shortcutLabel.alignment = .right
        shortcutLabel.isEditable = false
        shortcutLabel.isSelectable = false
        addSubview(shortcutLabel)

        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        shortcutLabel.frame = NSRect(x: bounds.width - 34, y: (bounds.height - 14) / 2, width: 24, height: 14)
    }

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
            PSTheme.accentSoft.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
