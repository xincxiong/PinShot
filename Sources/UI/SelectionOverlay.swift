import AppKit
import CoreGraphics

/// 一次选区操作的结果
enum SelectionOutcome {
    /// rect 为屏幕局部 Cocoa 坐标（原点左下，单位 pt），限制在 snapshot.frame.size 内
    case selected(snapshot: ScreenSnapshot, rect: CGRect)
    case cancelled
}

/// 覆盖视图的交互回调。只在 SelectionOverlay.swift 内部使用，不属于对外契约。
@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    /// 用户松开鼠标且选区有效（宽高均 ≥ 3pt）
    func selectionOverlayView(_ view: SelectionOverlayView, didCommit rect: CGRect)
    /// 用户取消（ESC / 右键 / 无效点击）
    func selectionOverlayViewDidCancel(_ view: SelectionOverlayView)
}

// MARK: - 控制器

/// 冻结帧框选控制器：每个屏幕一个覆盖窗，用户拖拽后回调一次。
///
/// 设计要点：
/// - 冻结帧截图在覆盖层出现前已经拍好，覆盖窗只负责「显示 + 框选」，永远截不到自己；
/// - 每块屏幕一个窗口，鼠标按下发生在哪块屏，就只在该屏产生选区（超过部分 clamp 到该屏）；
/// - 结果回调恰好一次：先 `dismiss()` 关闭全部窗口并移除事件监听，再调用 `onFinish`。
@MainActor
final class SelectionOverlayController {
    private let snapshots: [ScreenSnapshot]
    private let onFinish: (SelectionOutcome) -> Void

    private var windows: [SelectionOverlayWindow] = []
    private var keyMonitor: Any?
    private var finished = false
    private var presented = false

    init(snapshots: [ScreenSnapshot], onFinish: @escaping (SelectionOutcome) -> Void) {
        self.snapshots = snapshots
        self.onFinish = onFinish
    }

    // MARK: - 生命周期

    func present() {
        guard !presented, !finished else { return }
        presented = true

        guard !snapshots.isEmpty else {
            // 没有可框选的屏幕：直接按取消处理，保证调用方一定收到回调
            finish(.cancelled)
            return
        }

        // 激活 App 并让窗口成为 key，否则收不到键盘事件（ESC），首次点击也可能被吞。
        NSApp.activate(ignoringOtherApps: true)

        // 每块屏幕一个无边框覆盖窗，frame 直接对齐屏幕的全局 Cocoa frame。
        for snapshot in snapshots {
            let window = SelectionOverlayWindow(
                contentRect: snapshot.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            window.title = "PinShot 选区"

            let view = SelectionOverlayView(
                frame: CGRect(origin: .zero, size: snapshot.frame.size),
                snapshot: snapshot
            )
            view.delegate = self
            window.contentView = view
            windows.append(window)
        }

        // 先全部上屏；再把「鼠标所在屏」的窗口设为 key，保证 ESC 有接收方。
        for window in windows {
            window.orderFrontRegardless()
        }
        let mouseLocation = NSEvent.mouseLocation
        let keyWindow = windows.first(where: { $0.frame.contains(mouseLocation) }) ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        if let contentView = keyWindow?.contentView {
            keyWindow?.makeFirstResponder(contentView)
        }

        installKeyMonitor()

        // 切到别的 App（失焦）时取消。用 selector 形式保证回调在主线程。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    /// 关闭全部覆盖窗并移除监听；幂等，可重复调用。
    func dismiss() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 内部

    /// 本地 keyDown 监听：捕获 ESC（keyCode 53）并吞掉事件，避免系统响铃。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                self.finish(.cancelled)
            }
            return nil
        }
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        finish(.cancelled)
    }

    /// 保证回调恰好一次：先 dismiss（关窗 + 移除 monitor），再 onFinish。
    private func finish(_ outcome: SelectionOutcome) {
        guard !finished else { return }
        finished = true
        dismiss()
        onFinish(outcome)
    }
}

// MARK: - 覆盖视图回调

extension SelectionOverlayController: SelectionOverlayViewDelegate {
    func selectionOverlayView(_ view: SelectionOverlayView, didCommit rect: CGRect) {
        guard !finished else { return }
        let localBounds = CGRect(origin: .zero, size: view.snapshot.frame.size)
        let clamped = rect.intersection(localBounds)
        guard clamped.width >= 1, clamped.height >= 1 else {
            finish(.cancelled)
            return
        }
        finish(.selected(snapshot: view.snapshot, rect: clamped))
    }

    func selectionOverlayViewDidCancel(_ view: SelectionOverlayView) {
        finish(.cancelled)
    }
}

// MARK: - 覆盖窗

/// 覆盖窗：无边框、无阴影、透明背景，位于屏蔽层级（盖住菜单栏 / Dock / 全屏应用）。
/// `canBecomeKey = true` 以便接收键盘与鼠标。
@MainActor
final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 覆盖视图

/// 单屏冻结帧覆盖视图：绘制截图、遮罩挖孔、裁切角标、尺寸徽标与顶部提示。
///
/// 视觉语言沿用 PinShot 设计系统（Capture instrument）：暖石墨 + 信号橙，
/// 四角橙色 L 形裁切标记是选区状态的「视觉签名」，其余元素保持安静、不遮挡内容。
///
/// 同时用于 `--render-test` 离屏渲染：只依赖 `selectionRect` / `showsSizeBadge`，
/// 不读取 window / 鼠标状态，因此 `bitmapImageRepForCachingDisplay` + `cacheDisplay` 可直接出图。
final class SelectionOverlayView: NSView {
    /// 本视图对应的屏幕冻结帧
    let snapshot: ScreenSnapshot

    weak var delegate: SelectionOverlayViewDelegate?

    /// 已框选区域（视图局部 Cocoa 坐标，左下原点）。
    /// 交互时随拖动实时更新；离屏渲染自检时由调用方直接赋值。
    var selectionRect: CGRect? {
        didSet {
            if selectionRect != oldValue { needsDisplay = true }
        }
    }

    /// 是否绘制尺寸徽标（默认 true）
    var showsSizeBadge: Bool = true {
        didSet {
            if showsSizeBadge != oldValue { needsDisplay = true }
        }
    }

    // MARK: 交互状态

    private var isDragging = false
    private var anchorPoint: CGPoint = .zero

    // MARK: 视觉参数

    /// 未选中区域的压暗强度
    private let dimAlpha: CGFloat = 0.35
    /// 选区描边：白 95%
    private let borderAlpha: CGFloat = 0.95
    /// 徽标与选区之间的间距
    private let badgeGap: CGFloat = 8
    /// 徽标 / 提示距屏幕边缘的最小留白
    private let screenMargin: CGFloat = 6
    /// 顶部提示距屏幕顶边的距离（避开菜单栏 / 刘海）
    private let topInset: CGFloat = 44
    /// 四角裁切标记：线宽 2pt、臂长 18pt、距选区边缘 1pt
    private let cropMarkArm: CGFloat = 18
    private let cropMarkLineWidth: CGFloat = 2
    private let cropMarkGap: CGFloat = 1

    // MARK: - 初始化

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 保持非翻转坐标系：事件坐标即屏幕局部 Cocoa 坐标（左下原点），绘制方向见 draw(_:)。
    override var isFlipped: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    /// 允许 App 未激活时第一次点击就直接开始框选
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. 冻结帧截图铺满视图。
        //    视图是非翻转的（原点左下、y 向上），Quartz 在左下原点上下文中会把
        //    CGImage 的首行画到矩形顶部，方向正好是正确的，因此无需额外翻转。
        //    （若将来把 isFlipped 改成 true，需要 translate(0, height) + scale(1, -1)。）
        context.saveGState()
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.draw(snapshot.image, in: bounds)
        context.restoreGState()

        let selection = clampedSelection()

        // 2. 整屏压暗；有选区时用 even-odd 规则把选区挖空，保持原始亮度。
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        if let selection {
            let mask = NSBezierPath(rect: bounds)
            mask.append(NSBezierPath(rect: selection))
            mask.windingRule = .evenOdd
            mask.fill()
        } else {
            NSBezierPath(rect: bounds).fill()
        }

        // 空选区：只留顶部提示，保持低调
        guard let selection else {
            drawHint()
            return
        }

        // 3. 框选引导线：选区边中点延长到屏幕边缘（白 12%，1px）
        drawGuideLines(for: selection)

        // 4. 选区描边：1px 白 95%，画在选区内侧
        drawSelectionBorder(selection)

        // 5. 四角橙色 L 形裁切标记（本次改版的视觉签名）
        drawCropMarks(for: selection)

        // 6. 尺寸徽标：跟随选区右下，空间不足自动翻转 / 内收
        if showsSizeBadge {
            drawSizeBadge(for: selection)
        }
    }

    /// 取与视图 bounds 求交后的选区；过小 / 空选区视为「未选区」。
    private func clampedSelection() -> CGRect? {
        guard let rect = selectionRect else { return nil }
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 0.5, clipped.height >= 0.5 else { return nil }
        return clipped
    }

    // MARK: 引导线

    /// 从选区四条边的中点向对应屏幕边缘延伸的 1px 白 12% 引导线，共四条。
    private func drawGuideLines(for selection: CGRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()

        let midX = selection.midX
        let midY = selection.midY

        // 左、右
        path.move(to: CGPoint(x: selection.minX, y: midY))
        path.line(to: CGPoint(x: bounds.minX, y: midY))
        path.move(to: CGPoint(x: selection.maxX, y: midY))
        path.line(to: CGPoint(x: bounds.maxX, y: midY))
        // 上、下
        path.move(to: CGPoint(x: midX, y: selection.maxY))
        path.line(to: CGPoint(x: midX, y: bounds.maxY))
        path.move(to: CGPoint(x: midX, y: selection.minY))
        path.line(to: CGPoint(x: midX, y: bounds.minY))

        path.stroke()
    }

    // MARK: 描边

    private func drawSelectionBorder(_ selection: CGRect) {
        // inset 0.5 让 1pt 描边完全落在选区内侧
        let border = selection.insetBy(dx: 0.5, dy: 0.5)
        guard border.width > 0, border.height > 0 else { return }
        let path = NSBezierPath(rect: border)
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(borderAlpha).setStroke()
        path.stroke()
    }

    // MARK: 裁切角标

    /// 四角橙色 L 形裁切标记：2pt 线宽、18pt 臂长，折线中心线在选区外侧，
    /// 与选区边缘留 1pt 视觉间隙；贴近屏幕边缘时向内收敛，避免被裁掉。
    private func drawCropMarks(for selection: CGRect) {
        let lineWidth = cropMarkLineWidth
        let half = lineWidth / 2
        // 中心线相对选区边缘的外扩量：1pt 间隙 + 半个线宽
        let offset = cropMarkGap + half

        PSTheme.accent.setStroke()

        // (角点中心线坐标, 水平臂方向, 垂直臂方向)；臂方向指向选区内部
        let corners: [(point: CGPoint, horizontal: CGFloat, vertical: CGFloat)] = [
            (CGPoint(x: selection.minX - offset, y: selection.maxY + offset), 1, -1),   // 左上
            (CGPoint(x: selection.maxX + offset, y: selection.maxY + offset), -1, -1),  // 右上
            (CGPoint(x: selection.minX - offset, y: selection.minY - offset), 1, 1),    // 左下
            (CGPoint(x: selection.maxX + offset, y: selection.minY - offset), -1, 1),   // 右下
        ]

        for corner in corners {
            // 贴边时把折线中心线收进屏幕内，保证 2pt 线宽完整可见
            let x = clamp(corner.point.x, lower: bounds.minX + half, upper: bounds.maxX - half)
            let y = clamp(corner.point.y, lower: bounds.minY + half, upper: bounds.maxY - half)
            // 臂长同样收敛，避免超出屏幕
            let armEndX = clamp(x + corner.horizontal * cropMarkArm, lower: bounds.minX + half, upper: bounds.maxX - half)
            let armEndY = clamp(y + corner.vertical * cropMarkArm, lower: bounds.minY + half, upper: bounds.maxY - half)

            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .butt
            path.lineJoinStyle = .miter
            path.move(to: CGPoint(x: armEndX, y: y))
            path.line(to: CGPoint(x: x, y: y))
            path.line(to: CGPoint(x: x, y: armEndY))
            path.stroke()
        }
    }

    // MARK: 尺寸徽标

    /// 深色半透明胶囊：等宽数字 12pt medium 白色 + 小字 `pt` 10pt 白 55%，
    /// 1px 白 10% 边框、8pt 圆角；跟随选区右下，空间不足翻转。
    private func drawSizeBadge(for selection: CGRect) {
        let width = Int(selection.width.rounded())
        let height = Int(selection.height.rounded())

        let numberFont = PSTheme.mono(12, weight: .medium)
        let unitFont = PSTheme.mono(10, weight: .regular)
        let content = NSMutableAttributedString(
            string: "\(width) × \(height)",
            attributes: [
                .font: numberFont,
                .foregroundColor: NSColor.white,
            ]
        )
        content.append(NSAttributedString(
            string: " pt",
            attributes: [
                .font: unitFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]
        ))

        let contentSize = content.size()
        let padding = CGSize(width: 10, height: 5)
        let badgeSize = CGSize(
            width: contentSize.width + padding.width * 2,
            height: contentSize.height + padding.height * 2
        )

        // 默认贴选区右下外侧；下方空间不足翻到上方，左侧空间不足改为左对齐
        var origin = CGPoint(
            x: selection.maxX - badgeSize.width,
            y: selection.minY - badgeSize.height - badgeGap
        )
        if origin.y < bounds.minY + screenMargin {
            origin.y = selection.maxY + badgeGap
        }
        if origin.x < bounds.minX + screenMargin {
            origin.x = selection.minX
        }
        // 最后统一收进屏幕
        origin.x = clamp(origin.x, lower: bounds.minX + screenMargin, upper: bounds.maxX - screenMargin - badgeSize.width)
        origin.y = clamp(origin.y, lower: bounds.minY + screenMargin, upper: bounds.maxY - screenMargin - badgeSize.height)

        let badgeRect = CGRect(origin: origin, size: badgeSize)

        // 胶囊底：黑 72%
        NSColor.black.withAlphaComponent(0.72).setFill()
        let capsule = NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8)
        capsule.fill()

        // 1px 白 10% 边框（inset 0.5 落在胶囊内侧）
        let borderPath = NSBezierPath(roundedRect: badgeRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        borderPath.lineWidth = 1
        NSColor.white.withAlphaComponent(0.1).setStroke()
        borderPath.stroke()

        content.draw(at: CGPoint(
            x: badgeRect.minX + padding.width,
            y: badgeRect.midY - contentSize.height / 2
        ))
    }

    // MARK: 顶部提示

    /// 顶部居中半透明胶囊：`拖动框选` + 键帽 `ESC 取消`；仅在无选区时显示。
    private func drawHint() {
        let label = "拖动框选 · Shift 正方形" as NSString
        let labelFont = PSTheme.text(12, weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let labelSize = label.size(withAttributes: labelAttributes)

        // 键帽：18pt 高、1px 白 20% 边框、白 85% 等宽字
        let keycapText = "ESC 取消" as NSString
        let keycapFont = PSTheme.mono(11, weight: .medium)
        let keycapAttributes: [NSAttributedString.Key: Any] = [
            .font: keycapFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let keycapTextSize = keycapText.size(withAttributes: keycapAttributes)
        let keycapHeight: CGFloat = 18
        let keycapPaddingH: CGFloat = 7
        let keycapSize = CGSize(
            width: keycapTextSize.width + keycapPaddingH * 2,
            height: keycapHeight
        )

        let gap: CGFloat = 10
        let padding = CGSize(width: 12, height: 7)
        let contentHeight = max(labelSize.height, keycapHeight)
        let pillSize = CGSize(
            width: labelSize.width + gap + keycapSize.width + padding.width * 2,
            height: contentHeight + padding.height * 2
        )

        // 屏幕顶部居中，低调半透明
        var origin = CGPoint(
            x: bounds.midX - pillSize.width / 2,
            y: bounds.maxY - topInset - pillSize.height
        )
        origin.x = clamp(origin.x, lower: bounds.minX + screenMargin, upper: bounds.maxX - screenMargin - pillSize.width)
        origin.y = clamp(origin.y, lower: bounds.minY + screenMargin, upper: bounds.maxY - screenMargin - pillSize.height)

        let pillRect = CGRect(origin: origin, size: pillSize)
        NSColor.black.withAlphaComponent(0.5).setFill()
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillSize.height / 2, yRadius: pillSize.height / 2)
        pill.fill()

        // 左侧文案，垂直居中
        label.draw(
            at: CGPoint(
                x: pillRect.minX + padding.width,
                y: pillRect.midY - labelSize.height / 2
            ),
            withAttributes: labelAttributes
        )

        // 右侧键帽
        let keycapRect = CGRect(
            x: pillRect.minX + padding.width + labelSize.width + gap,
            y: pillRect.midY - keycapHeight / 2,
            width: keycapSize.width,
            height: keycapHeight
        )
        let keycapPath = NSBezierPath(roundedRect: keycapRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.08).setFill()
        keycapPath.fill()
        keycapPath.lineWidth = 1
        NSColor.white.withAlphaComponent(0.2).setStroke()
        keycapPath.stroke()

        keycapText.draw(
            at: CGPoint(
                x: keycapRect.midX - keycapTextSize.width / 2,
                y: keycapRect.midY - keycapTextSize.height / 2
            ),
            withAttributes: keycapAttributes
        )
    }

    // MARK: - 鼠标 / 键盘

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if !window.isKeyWindow {
            window.makeKey()
        }
        window.makeFirstResponder(self)

        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        isDragging = true
        anchorPoint = point
        selectionRect = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        selectionRect = CGRect(from: anchorPoint, to: constrainedPoint(point, square: event.modifierFlags.contains(.shift)))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false

        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        let rect = CGRect(from: anchorPoint, to: constrainedPoint(point, square: event.modifierFlags.contains(.shift)))
        selectionRect = rect

        // 宽或高 < 3pt 视为误触，取消整次截图
        if rect.width >= 3, rect.height >= 3 {
            delegate?.selectionOverlayView(self, didCommit: rect)
        } else {
            delegate?.selectionOverlayViewDidCancel(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionOverlayViewDidCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        // 本地 monitor 已优先拦截 ESC，这里作为兜底
        if event.keyCode == 53 {
            delegate?.selectionOverlayViewDidCancel(self)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 坐标工具

    /// `Shift` 约束为正方形：以按下点为一个角，取水平/垂直中较大的边长，并限制在屏幕内。
    private func constrainedPoint(_ point: CGPoint, square: Bool) -> CGPoint {
        guard square else { return point }
        let dx = point.x - anchorPoint.x
        let dy = point.y - anchorPoint.y
        let side = max(abs(dx), abs(dy))
        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let maxX = signX > 0 ? bounds.maxX - anchorPoint.x : anchorPoint.x - bounds.minX
        let maxY = signY > 0 ? bounds.maxY - anchorPoint.y : anchorPoint.y - bounds.minY
        let fitted = min(side, max(0, maxX), max(0, maxY))
        return CGPoint(x: anchorPoint.x + signX * fitted, y: anchorPoint.y + signY * fitted)
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: clamp(point.x, lower: bounds.minX, upper: bounds.maxX),
            y: clamp(point.y, lower: bounds.minY, upper: bounds.maxY)
        )
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        // upper 可能小于 lower（例如选区比屏幕还大时），此时取 lower 保证不越界
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

// MARK: - 工具

private extension CGRect {
    /// 由两个任意方向的点构造标准化矩形（宽高非负）
    init(from a: CGPoint, to b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
