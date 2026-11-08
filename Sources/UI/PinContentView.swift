import AppKit

// MARK: - 工具栏回调

/// 悬停工具栏的按钮回调。用协议而不是闭包，避免闭包与 MainActor 隔离之间的摩擦。
@MainActor
protocol PinToolbarDelegate: AnyObject {
    func pinToolbarDidTapCopy()
    func pinToolbarDidTapSave()
    func pinToolbarDidTapRecognizeText()
    func pinToolbarDidTapToggleAutoHide()
    func pinToolbarDidTapTogglePlacement()
    func pinToolbarDidTapClose()
}

// MARK: - 内容视图

/// 挂件内容视图：
/// - 绘制等比铺满的截图、圆角裁切、1pt 自适应边框；
/// - 悬停约 0.12s 淡入工具栏（复制 / 保存 / 自动隐藏 / 放置模式 / 关闭）；
/// - 右键菜单（复制、存储为、存桌面、自动隐藏、贴在桌面、缩放、不透明度、关闭、全部关闭）；
/// - 拖拽移动、四角等比缩放（对角锚点 + 尺寸徽标）、⌘C / ⌘S / ⌘W / Esc / 方向键。
@MainActor
final class PinContentView: NSView, PinToolbarDelegate {

    // MARK: 子类型

    private enum InteractionMode: Equatable {
        case none
        case dragging
        case resizing
    }

    /// 四个角的缩放手柄；拖拽时以对角为锚点。
    private enum ResizeCorner: CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    // MARK: 属性

    private unowned let controller: PinWindowController
    private let image: PinnedImage
    /// 缓存 NSImage，避免每次 draw 重新包装 CGImage
    private let nsImage: NSImage
    private let borderColor: NSColor

    private let toolbar = PinToolbarView()
    private var trackingArea: NSTrackingArea?
    private var toolbarSuppressed = false
    private var forceToolbarVisible = false
    private var toolbarShowTimer: Timer?
    private var toolbarHideTimer: Timer?

    private var interaction: InteractionMode = .none
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrame: CGRect = .zero

    /// 正在拖拽的缩放角
    private var activeResizeCorner: ResizeCorner?
    private var resizeStartMouseLocation: NSPoint = .zero
    private var resizeStartFrame: CGRect = .zero
    private var resizeAnchorPoint: CGPoint = .zero

    /// 悬停时显示四个角的白色圆点把手
    private var showsResizeHandles = false

    private lazy var resizeCursorNWSE: NSCursor = PinContentView.makeResizeCursor(flipped: false)
    private lazy var resizeCursorNESW: NSCursor = PinContentView.makeResizeCursor(flipped: true)

    // MARK: 初始化

    init(frame frameRect: NSRect, controller: PinWindowController, image: PinnedImage) {
        self.controller = controller
        self.image = image
        self.nsImage = image.nsImage
        self.borderColor = PinContentView.adaptiveBorderColor(for: image.cgImage)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = PinShotConstants.pinCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        toolbar.delegate = self
        addSubview(toolbar)

        updateToolbarFrame()
        toolbar.alphaValue = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        toolbarShowTimer?.invalidate()
        toolbarHideTimer?.invalidate()
    }

    // MARK: 绘制

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 图片等比铺满整个视图（NSImage 使用点尺寸，Retina 下自动取全分辨率像素）
        nsImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        )

        if AppSettings.shared.showPinBorder {
            // 1pt 边框（内缩半个线宽，避免被圆角裁掉一半）
            let width = PinShotConstants.pinBorderWidth
            let borderRect = bounds.insetBy(dx: width / 2, dy: width / 2)
            let path = NSBezierPath(
                roundedRect: borderRect,
                xRadius: PinShotConstants.pinCornerRadius,
                yRadius: PinShotConstants.pinCornerRadius
            )
            path.lineWidth = width
            borderColor.setStroke()
            path.stroke()
        }

        // 四角缩放把手（悬停时显示；离屏渲染不绘制）
        if showsResizeHandles, !controller.renderOnly {
            drawResizeHandles()
        }

        // 拖拽缩放期间的尺寸徽标（松手后消失）
        if interaction == .resizing, !controller.renderOnly {
            drawResizeSizeBadge()
        }
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        updateToolbarFrame()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateToolbarFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolbarFrame()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        window?.invalidateCursorRects(for: self)
    }

    private func updateToolbarFrame() {
        let size = toolbar.preferredSize
        let margin: CGFloat = 10
        let x = max(margin, bounds.maxX - size.width - margin)
        let y = max(margin, bounds.maxY - size.height - margin)
        toolbar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 工具栏能否完整放进当前尺寸（最小 40×40 的挂件放不下，此时用右键菜单）
    private var toolbarFits: Bool {
        let size = toolbar.preferredSize
        return bounds.width >= size.width + 20 && bounds.height >= size.height + 20
    }

    // MARK: 设置变化

    /// 设置变化时刷新边框 / 工具栏开关图标。
    func settingsDidChange() {
        needsDisplay = true
        toolbar.updateAutoHideButton()
        if controller.isAutoHidden || controller.isForcedHidden {
            hideToolbar(animated: false)
        }
    }

    /// 放置模式切换后刷新工具栏图标与画面。
    func placementDidChange() {
        toolbar.updatePlacementButton(isDesktop: controller.pinPlacement == .desktop)
        needsDisplay = true
    }

    // MARK: 工具栏显隐

    /// 自动隐藏 / 强制隐藏时抑制工具栏。
    func setToolbarSuppressed(_ suppressed: Bool) {
        toolbarSuppressed = suppressed
        if suppressed {
            cancelToolbarTimers()
            hideToolbar(animated: false)
        }
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        cancelToolbarTimers()
        if visible {
            showToolbar()
        } else if animated {
            hideToolbar(animated: true)
        } else {
            toolbar.alphaValue = 0
        }
    }

    /// 鼠标离开 / 拖拽结束后，按当前鼠标位置刷新工具栏。
    func refreshToolbarForCurrentMouse() {
        guard !controller.renderOnly, let window else { return }
        updateResizeHandlesVisibility()
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        if bounds.contains(point) {
            scheduleToolbarShow()
        } else {
            scheduleToolbarHide()
        }
    }

    private func scheduleToolbarShow() {
        toolbarHideTimer?.invalidate()
        toolbarHideTimer = nil
        guard toolbarShowTimer == nil else { return }
        guard !toolbarSuppressed, toolbarFits else { return }

        let timer = Timer(
            timeInterval: 0.12,
            target: self,
            selector: #selector(toolbarShowTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        toolbarShowTimer = timer
    }

    private func scheduleToolbarHide() {
        toolbarShowTimer?.invalidate()
        toolbarShowTimer = nil
        guard toolbarHideTimer == nil else { return }

        let timer = Timer(
            timeInterval: 0.15,
            target: self,
            selector: #selector(toolbarHideTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        toolbarHideTimer = timer
    }

    private func cancelToolbarTimers() {
        toolbarShowTimer?.invalidate()
        toolbarShowTimer = nil
        toolbarHideTimer?.invalidate()
        toolbarHideTimer = nil
    }

    @objc private func toolbarShowTimerFired() {
        toolbarShowTimer = nil
        showToolbar()
    }

    @objc private func toolbarHideTimerFired() {
        toolbarHideTimer = nil
        hideToolbar(animated: true)
    }

    private func showToolbar() {
        guard !toolbarSuppressed,
              !controller.isAutoHidden,
              !controller.isForcedHidden else { return }
        guard forceToolbarVisible || toolbarFits else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.toolbar.animator().alphaValue = 1
        }
    }

    private func hideToolbar(animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.toolbar.animator().alphaValue = 0
            }
        } else {
            toolbar.alphaValue = 0
        }
    }

    // MARK: 悬停跟踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleToolbarShow()
        updateResizeHandlesVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        scheduleToolbarHide()
        if interaction != .resizing {
            showsResizeHandles = false
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeHandlesVisibility()
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(for: point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for corner in ResizeCorner.allCases {
            addCursorRect(handleRect(for: corner), cursor: cursor(for: corner))
        }
    }

    // MARK: 四角缩放手柄

    /// 16pt 命中热区（四角）
    private func handleRect(for corner: ResizeCorner) -> CGRect {
        let size = PinShotConstants.resizeHandleSize
        switch corner {
        case .topLeft:
            return CGRect(x: bounds.minX, y: bounds.maxY - size, width: size, height: size)
        case .topRight:
            return CGRect(x: bounds.maxX - size, y: bounds.maxY - size, width: size, height: size)
        case .bottomLeft:
            return CGRect(x: bounds.minX, y: bounds.minY, width: size, height: size)
        case .bottomRight:
            return CGRect(x: bounds.maxX - size, y: bounds.minY, width: size, height: size)
        }
    }

    private func handleCenter(for corner: ResizeCorner) -> CGPoint {
        let inset: CGFloat = 7
        switch corner {
        case .topLeft:
            return CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset)
        case .topRight:
            return CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
        case .bottomLeft:
            return CGPoint(x: bounds.minX + inset, y: bounds.minY + inset)
        case .bottomRight:
            return CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset)
        }
    }

    private func resizeCorner(at point: CGPoint) -> ResizeCorner? {
        for corner in ResizeCorner.allCases where handleRect(for: corner).contains(point) {
            return corner
        }
        return nil
    }

    /// 白色小圆点把手（外圈深色，任何图片上都清晰）
    private func drawResizeHandles() {
        let radius: CGFloat = 3
        for corner in ResizeCorner.allCases {
            let center = handleCenter(for: corner)
            let halo = CGRect(
                x: center.x - radius - 1,
                y: center.y - radius - 1,
                width: (radius + 1) * 2,
                height: (radius + 1) * 2
            )
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: halo).fill()

            let dot = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// 拖拽缩放期间：图片底部居中的尺寸徽标（等宽 11pt，如 640 × 420）
    private func drawResizeSizeBadge() {
        let text = "\(Int(bounds.width.rounded())) × \(Int(bounds.height.rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.mono(11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 4)
        let badgeHeight = ceil(textSize.height) + padding.height * 2
        let badgeWidth = min(ceil(textSize.width) + padding.width * 2, max(bounds.width - 8, 1))
        let rect = CGRect(
            x: ((bounds.width - badgeWidth) / 2).rounded(),
            y: 10,
            width: badgeWidth,
            height: badgeHeight
        )
        let background = NSBezierPath(
            roundedRect: rect,
            xRadius: badgeHeight / 2,
            yRadius: badgeHeight / 2
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        background.fill()

        // 徽标比窗口还窄时裁剪文字，避免溢出
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).addClip()
        text.draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func cursor(for corner: ResizeCorner) -> NSCursor {
        switch corner {
        case .topLeft, .bottomRight:
            return resizeCursorNWSE
        case .topRight, .bottomLeft:
            return resizeCursorNESW
        }
    }

    private func updateCursor(for point: NSPoint) {
        switch interaction {
        case .dragging:
            NSCursor.closedHand.set()
        case .resizing:
            if let activeResizeCorner {
                cursor(for: activeResizeCorner).set()
            } else {
                resizeCursorNWSE.set()
            }
        case .none:
            if let corner = resizeCorner(at: point) {
                cursor(for: corner).set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// 鼠标是否在内容范围内（用于悬停显示把手）
    private var isMouseInsideContent: Bool {
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(pointInWindow, from: nil))
    }

    private func updateResizeHandlesVisibility() {
        let shouldShow = !controller.renderOnly && (interaction == .resizing || isMouseInsideContent)
        if showsResizeHandles != shouldShow {
            showsResizeHandles = shouldShow
            needsDisplay = true
        }
    }

    // MARK: 鼠标：拖拽 / 缩放

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(self)
        cancelToolbarTimers()
        hideToolbar(animated: false)

        let point = convert(event.locationInWindow, from: nil)
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = window.frame

        if let corner = resizeCorner(at: point) {
            interaction = .resizing
            activeResizeCorner = corner
            resizeStartMouseLocation = dragStartMouseLocation
            resizeStartFrame = window.frame
            resizeAnchorPoint = anchorPoint(for: corner, in: window.frame)
        } else {
            interaction = .dragging
            activeResizeCorner = nil
        }

        showsResizeHandles = !controller.renderOnly && interaction == .resizing
        needsDisplay = true
        controller.beginInteraction()
        updateCursor(for: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation

        switch interaction {
        case .dragging:
            NSCursor.closedHand.set()
            let dx = current.x - dragStartMouseLocation.x
            let dy = current.y - dragStartMouseLocation.y
            let moved = dragStartFrame.offsetBy(dx: dx, dy: dy)
            let visible = visibleFrame(containing: moved)
            window.setFrameOrigin(CaptureGeometry.clampedWindowFrame(moved, visibleFrame: visible).origin)

        case .resizing:
            guard let corner = activeResizeCorner else { break }
            cursor(for: corner).set()
            let dx = current.x - resizeStartMouseLocation.x
            let dy = current.y - resizeStartMouseLocation.y
            let startSize = resizeStartFrame.size
            let ratio = startSize.width / max(startSize.height, 1)

            // 以被拖拽角的方向判断「拖大 / 拖小」：右侧角向右增大、左侧角向左增大；
            // 顶部角向上增大、底部角向下增大。
            let horizontalSign: CGFloat = (corner == .bottomRight || corner == .topRight) ? 1 : -1
            let verticalSign: CGFloat = (corner == .topRight || corner == .topLeft) ? 1 : -1
            let widthDelta = dx * horizontalSign
            let heightDelta = dy * verticalSign

            // 水平拖动为主时用宽度变化；垂直拖动为主时按比例换算成宽度
            var proposedWidth = abs(widthDelta) >= abs(heightDelta)
                ? startSize.width + widthDelta
                : (startSize.height + heightDelta) * ratio

            // 以对角为锚点：右下角不能超出所在屏幕可视区域
            let visible = visibleFrame(containing: resizeStartFrame)
            let anchor = resizeAnchorPoint
            let maxWidthX = horizontalSign > 0
                ? visible.maxX - anchor.x
                : anchor.x - visible.minX
            let maxHeightY = verticalSign > 0
                ? visible.maxY - anchor.y
                : anchor.y - visible.minY
            let maxWidth = max(
                PinShotConstants.minPinSize.width,
                min(maxWidthX, maxHeightY * ratio)
            )
            proposedWidth = min(maxWidth, max(PinShotConstants.minPinSize.width, proposedWidth))

            let newSize = CaptureGeometry.resizedSize(
                from: startSize,
                to: CGSize(width: proposedWidth, height: 0),
                minSize: PinShotConstants.minPinSize
            )
            // 对角锚点固定，按被拖拽的角决定新的 origin
            let origin: CGPoint
            switch corner {
            case .topLeft:      // 锚点 = 右下角
                origin = CGPoint(x: anchor.x - newSize.width, y: anchor.y)
            case .topRight:     // 锚点 = 左下角
                origin = CGPoint(x: anchor.x, y: anchor.y)
            case .bottomLeft:   // 锚点 = 右上角
                origin = CGPoint(x: anchor.x - newSize.width, y: anchor.y - newSize.height)
            case .bottomRight:  // 锚点 = 左上角
                origin = CGPoint(x: anchor.x, y: anchor.y - newSize.height)
            }
            window.setFrame(CGRect(origin: origin, size: newSize), display: true)
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasInteracting = interaction != .none
        interaction = .none
        activeResizeCorner = nil

        if wasInteracting {
            // 松开鼠标后兜底：至少保留 40pt 在屏幕内
            if let window {
                let visible = visibleFrame(containing: window.frame)
                let clamped = CaptureGeometry.clampedWindowFrame(window.frame, visibleFrame: visible)
                if clamped != window.frame {
                    window.setFrame(clamped, display: true)
                }
                window.invalidateCursorRects(for: self)
            }
            controller.endInteraction()
            refreshToolbarForCurrentMouse()
        }

        updateResizeHandlesVisibility()
        updateCursor(for: convert(event.locationInWindow, from: nil))
    }

    /// 拖拽某角时固定的对角锚点（全局 Cocoa 坐标：原点左下、y 向上）
    private func anchorPoint(for corner: ResizeCorner, in frame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:      // 固定右下角
            return CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight:     // 固定左下角
            return CGPoint(x: frame.minX, y: frame.minY)
        case .bottomLeft:   // 固定右上角
            return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight:  // 固定左上角
            return CGPoint(x: frame.minX, y: frame.maxY)
        }
    }

    // MARK: 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        guard !controller.renderOnly else { return }
        window?.orderFrontRegardless()
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let menu = makeContextMenu()
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(makeItem(
            title: "复制图片", action: #selector(menuCopy),
            keyEquivalent: "c", symbol: "doc.on.doc"
        ))
        menu.addItem(makeItem(
            title: "存储为…", action: #selector(menuSaveAs),
            keyEquivalent: "s", symbol: "square.and.arrow.down"
        ))
        menu.addItem(makeItem(
            title: "识别文字…", action: #selector(menuRecognizeText),
            keyEquivalent: "t", symbol: "text.viewfinder"
        ))
        let saveDesktop = makeItem(
            title: "存储到桌面", action: #selector(menuSaveToDesktop),
            symbol: "desktopcomputer"
        )
        saveDesktop.keyEquivalent = "s"
        saveDesktop.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveDesktop)

        menu.addItem(.separator())

        let autoHideEnabled = AppSettings.shared.autoHideEnabled
        let autoHide = makeItem(
            title: "自动隐藏", action: #selector(menuToggleAutoHide),
            symbol: autoHideEnabled ? "eye" : "eye.slash"
        )
        autoHide.state = autoHideEnabled ? .on : .off
        menu.addItem(autoHide)

        // 放置模式（勾选）
        let isDesktop = controller.pinPlacement == .desktop
        let placementItem = makeItem(
            title: "贴在桌面", action: #selector(menuTogglePlacement),
            symbol: isDesktop ? "desktopcomputer" : "pin.fill"
        )
        placementItem.state = isDesktop ? .on : .off
        menu.addItem(placementItem)

        // 缩放子菜单：基于原图 pointSize
        let scaleMenu = NSMenu()
        let currentFactor = window.map { $0.frame.width / max(image.pointSize.width, 1) } ?? 1
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(
                title: "\(percent)%",
                action: #selector(menuScalePreset(_:)),
                keyEquivalent: ""
            )
            item.tag = percent
            item.target = self
            item.state = abs(currentFactor - CGFloat(percent) / 100) < 0.01 ? .on : .off
            scaleMenu.addItem(item)
        }
        let fitItem = NSMenuItem(
            title: "适合屏幕",
            action: #selector(menuScalePreset(_:)),
            keyEquivalent: ""
        )
        fitItem.tag = -1
        fitItem.target = self
        scaleMenu.addItem(fitItem)
        let scaleItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        scaleItem.image = Self.menuSymbol("arrow.up.left.and.arrow.down.right")
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)

        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(menuOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            let value = CGFloat(percent) / 100.0
            item.state = abs(controller.userAlpha - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.image = Self.menuSymbol("circle.lefthalf.filled")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(makeItem(
            title: "关闭", action: #selector(menuClose),
            keyEquivalent: "w", symbol: "xmark"
        ))
        menu.addItem(makeItem(
            title: "全部关闭", action: #selector(menuCloseAll),
            symbol: "xmark.circle"
        ))

        return menu
    }

    private func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbol {
            item.image = Self.menuSymbol(symbol)
        }
        return item
    }

    /// 菜单项图标：SF Symbols 模板图，跟随系统浅色 / 深色自适应。
    private static func menuSymbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    @objc private func menuCopy() {
        controller.copyToPasteboard()
    }

    @objc private func menuRecognizeText() {
        controller.recognizeText()
    }

    @objc private func menuSaveAs() {
        controller.saveImage(saveAs: true)
    }

    @objc private func menuSaveToDesktop() {
        controller.saveImage(saveAs: false)
    }

    @objc private func menuToggleAutoHide() {
        AppSettings.shared.autoHideEnabled.toggle()
    }

    @objc private func menuTogglePlacement() {
        controller.togglePlacement()
    }

    @objc private func menuScalePreset(_ sender: NSMenuItem) {
        if sender.tag <= 0 {
            controller.setScalePreset(0) // 适合屏幕
        } else {
            controller.setScalePreset(CGFloat(sender.tag) / 100.0)
        }
    }

    @objc private func menuOpacity(_ sender: NSMenuItem) {
        controller.setUserAlpha(CGFloat(sender.tag) / 100.0)
    }

    @objc private func menuClose() {
        requestClose()
    }

    @objc private func menuCloseAll() {
        // 延后到当前菜单 / 事件回调结束，避免在自己回调栈里销毁视图层级
        Task { @MainActor in
            PinManager.shared.closeAll()
        }
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: // Esc
            requestClose()
        case 123: // ←
            nudge(dx: -step, dy: 0)
        case 124: // →
            nudge(dx: step, dy: 0)
        case 125: // ↓
            nudge(dx: 0, dy: -step)
        case 126: // ↑
            nudge(dx: 0, dy: step)
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch key {
        case "c":
            controller.copyToPasteboard()
            return true
        case "s":
            controller.saveImage(saveAs: !event.modifierFlags.contains(.shift))
            return true
        case "t":
            controller.recognizeText()
            return true
        case "w":
            requestClose()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        let moved = window.frame.offsetBy(dx: dx, dy: dy)
        let visible = visibleFrame(containing: moved)
        var frame = moved
        // 方向键微调：严格限制在可视区域内
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        window.setFrameOrigin(frame.origin)
    }

    // MARK: 离屏渲染支持

    /// 强制显示工具栏并置 alpha=1，供 `renderDebugPNG` 使用。
    func prepareForDebugRendering() {
        cancelToolbarTimers()
        forceToolbarVisible = true
        toolbar.alphaValue = 1
        toolbar.isHidden = false
        // 离屏 cacheDisplay 拿不到窗口服务器的实时模糊，加深叠层模拟深色磨砂玻璃
        toolbar.setOffscreenRendering(true)
        updateToolbarFrame()
        toolbar.updateAutoHideButton()
        toolbar.updatePlacementButton(isDesktop: controller.pinPlacement == .desktop)
        // 离屏渲染不显示缩放把手 / 尺寸徽标
        showsResizeHandles = false
        activeResizeCorner = nil
        needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    func finishDebugRendering() {
        forceToolbarVisible = false
        toolbar.setOffscreenRendering(false)
        toolbar.alphaValue = 0
        updateResizeHandlesVisibility()
    }

    /// 关闭当前挂件。
    /// 通过 Task 延后到当前事件回调结束：拖拽 / 工具栏按钮 / 菜单动作的调用栈里
    /// 还可能继续访问内容视图，同步销毁视图层级会有 use-after-free 风险。
    private func requestClose() {
        let controller = self.controller
        Task { @MainActor in
            controller.closePin()
        }
    }

    // MARK: PinToolbarDelegate

    func pinToolbarDidTapCopy() {
        window?.makeFirstResponder(self)
        controller.copyToPasteboard()
    }

    func pinToolbarDidTapSave() {
        window?.makeFirstResponder(self)
        controller.saveImage(saveAs: true)
    }

    func pinToolbarDidTapRecognizeText() {
        window?.makeFirstResponder(self)
        controller.recognizeText()
    }

    func pinToolbarDidTapToggleAutoHide() {
        window?.makeFirstResponder(self)
        AppSettings.shared.autoHideEnabled.toggle()
        toolbar.updateAutoHideButton()
    }

    func pinToolbarDidTapTogglePlacement() {
        window?.makeFirstResponder(self)
        controller.togglePlacement()
    }

    func pinToolbarDidTapClose() {
        requestClose()
    }

    // MARK: 辅助

    /// 取与 rect 相交面积最大的屏幕的可视区域
    private func visibleFrame(containing rect: CGRect) -> CGRect {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        if let bestScreen {
            return bestScreen.visibleFrame
        }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? rect
    }

    /// 根据图片平均亮度选择边框颜色：浅色图片用深色描边，深色图片用白色描边。
    private static func adaptiveBorderColor(for cgImage: CGImage) -> NSColor {
        let luminance = averageLuminance(of: cgImage)
        if luminance > 0.6 {
            return NSColor.black.withAlphaComponent(0.35)
        }
        return NSColor.white.withAlphaComponent(0.45)
    }

    private static func averageLuminance(of cgImage: CGImage) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drew = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return 0 }
        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// 斜向缩放光标（纯 AppKit 离屏绘制，白描边 + 黑内芯，任何背景都可见）。
    /// - flipped == false：NW-SE（左上 ↔ 右下，用于左上 / 右下角）
    /// - flipped == true ：NE-SW（右上 ↔ 左下，用于右上 / 左下角）
    private static func makeResizeCursor(flipped: Bool) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 4
            let start = flipped
                ? NSPoint(x: side - inset, y: side - inset)   // 右上
                : NSPoint(x: inset, y: side - inset)          // 左上
            let end = flipped
                ? NSPoint(x: inset, y: inset)                 // 左下
                : NSPoint(x: side - inset, y: inset)          // 右下
            let arrow: CGFloat = 5
            let xSign: CGFloat = end.x > start.x ? 1 : -1
            let ySign: CGFloat = end.y > start.y ? 1 : -1

            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            // 起点箭头
            path.move(to: NSPoint(x: start.x + xSign * arrow, y: start.y))
            path.line(to: start)
            path.line(to: NSPoint(x: start.x, y: start.y + ySign * arrow))
            // 终点箭头
            path.move(to: NSPoint(x: end.x - xSign * arrow, y: end.y))
            path.line(to: end)
            path.line(to: NSPoint(x: end.x, y: end.y - ySign * arrow))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()

            NSColor.black.setStroke()
            path.lineWidth = 1.8
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

// MARK: - 工具栏

/// 悬浮工具栏：32pt 高的磨砂玻璃（NSVisualEffectView HUD 材质），
/// 10pt 连续圆角 + 1px 白色 12% 描边，内含 5 个 24×24 圆形按钮
/// （复制 / 存储 / 自动隐藏 / 放置模式 / 关闭，顺序不变）。
@MainActor
final class PinToolbarView: NSVisualEffectView {
    weak var delegate: PinToolbarDelegate?

    static let buttonSize: CGFloat = 24
    static let toolbarHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 10

    private let spacing: CGFloat = 2
    private let horizontalPadding: CGFloat = 4
    /// 深色叠层：真实运行时压住 HUD 材质亮度，离屏渲染时作为兜底底色
    private let tintView = NSView()
    /// 1px 白色 12% 描边（独立视图，保证离屏渲染也能画出来）
    private let borderView = PinToolbarBorderView()
    private var buttons: [PinToolbarButton] = []

    var preferredSize: NSSize {
        let count = CGFloat(buttons.count)
        let width = horizontalPadding * 2 + Self.buttonSize * count + spacing * max(0, count - 1)
        return NSSize(width: width, height: Self.toolbarHeight)
    }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = Self.tintColor(alpha: 0.22).cgColor
        addSubview(tintView)
        addSubview(borderView)

        alphaValue = 0
        configureButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        tintView.frame = bounds
        borderView.frame = bounds
        let y = (bounds.height - Self.buttonSize) / 2
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: horizontalPadding + CGFloat(index) * (Self.buttonSize + spacing),
                y: y,
                width: Self.buttonSize,
                height: Self.buttonSize
            )
        }
    }

    /// 只有按钮响应点击；玻璃底留白不拦截，交给内容视图拖动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.05, !isHidden else { return nil }
        let local = convert(point, from: superview)
        for button in buttons where button.frame.contains(local) {
            return button
        }
        return nil
    }

    /// 离屏渲染时 HUD 材质的实时模糊不可用（cacheDisplay 只会拿到材质 fallback），
    /// 用更深的叠层模拟深色磨砂玻璃，避免渲染图变成浅灰块。
    func setOffscreenRendering(_ enabled: Bool) {
        let alpha: CGFloat = enabled ? 0.72 : 0.22
        tintView.layer?.backgroundColor = Self.tintColor(alpha: alpha).cgColor
        borderView.needsDisplay = true
    }

    private static func tintColor(alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: alpha)
    }

    private func configureButtons() {
        let specs: [(PinToolbarButton.Kind, String, String)] = [
            (.copy, "doc.on.doc", "复制图片 ⌘C"),
            (.save, "square.and.arrow.down", "存储为… ⌘S"),
            (.recognizeText, "text.viewfinder", "识别文字 ⌘T"),
            (.toggleAutoHide, "eye", "自动隐藏"),
            (.togglePlacement, "pin.fill", "浮于顶层"),
            (.close, "xmark", "关闭 ⌘W")
        ]
        for spec in specs {
            let button = PinToolbarButton(kind: spec.0, symbolName: spec.1, accessibilityLabel: spec.2)
            button.toolbar = self
            addSubview(button)
            buttons.append(button)
        }
        updateAutoHideButton()
    }

    /// 自动隐藏开关图标 / 提示随全局设置更新：
    /// 开启时眼睛用信号橙提示开启态，关闭时回到白色。
    func updateAutoHideButton() {
        guard let button = buttons.first(where: { $0.kind == .toggleAutoHide }) else { return }
        let enabled = AppSettings.shared.autoHideEnabled
        let symbolName = enabled ? "eye" : "eye.slash"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = image.withSymbolConfiguration(configuration) ?? image
            button.image?.isTemplate = true
        }
        button.contentTintColor = enabled ? PSTheme.accent : .white

        let tooltip = enabled ? "自动隐藏：开（点击关闭）" : "自动隐藏：关（点击开启）"
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.needsDisplay = true
    }

    /// 放置模式按钮：桌面时 desktopcomputer，浮于顶层时 pin.fill。
    func updatePlacementButton(isDesktop: Bool) {
        guard let button = buttons.first(where: { $0.kind == .togglePlacement }) else { return }
        let symbolName = isDesktop ? "desktopcomputer" : "pin.fill"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = image.withSymbolConfiguration(configuration) ?? image
            button.image?.isTemplate = true
        }
        button.contentTintColor = .white
        let tooltip = isDesktop
            ? "挂在桌面（点击浮于顶层）"
            : "浮于顶层（点击挂到桌面）"
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.needsDisplay = true
    }

    fileprivate func handleTap(_ kind: PinToolbarButton.Kind) {
        switch kind {
        case .copy:
            delegate?.pinToolbarDidTapCopy()
        case .save:
            delegate?.pinToolbarDidTapSave()
        case .recognizeText:
            delegate?.pinToolbarDidTapRecognizeText()
        case .toggleAutoHide:
            delegate?.pinToolbarDidTapToggleAutoHide()
        case .togglePlacement:
            delegate?.pinToolbarDidTapTogglePlacement()
        case .close:
            delegate?.pinToolbarDidTapClose()
        }
    }
}

/// 工具栏 1px 白色 12% 圆角描边。单独成层，不参与命中测试。
@MainActor
final class PinToolbarBorderView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = PinToolbarView.cornerRadius - 0.5
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 工具栏按钮：24×24 命中区，12pt SF Symbol；
/// hover 白色 16% 圆形底，按下 26% 圆形底。
@MainActor
final class PinToolbarButton: NSButton {
    enum Kind: Int {
        case copy
        case save
        case recognizeText
        case toggleAutoHide
        case togglePlacement
        case close
    }

    let kind: Kind
    weak var toolbar: PinToolbarView?

    private var isHovering = false
    private var isPressing = false
    private var trackingArea: NSTrackingArea?

    init(kind: Kind, symbolName: String, accessibilityLabel: String) {
        self.kind = kind
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            self.image = image.withSymbolConfiguration(configuration) ?? image
            self.image?.isTemplate = true
        }
        contentTintColor = .white
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)

        target = self
        action = #selector(clicked)
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
        // hover / 按下：白色半透明圆形底（16% / 26%）
        if isHovering || isPressing {
            let alpha: CGFloat = isPressing ? 0.26 : 0.16
            NSColor(calibratedWhite: 1, alpha: alpha).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func clicked() {
        toolbar?.handleTap(kind)
    }
}
