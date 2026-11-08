import AppKit
import UniformTypeIdentifiers

/// 置顶挂件窗口控制器。
///
/// 负责：
/// - 无边框、非激活式（nonactivating）置顶 `NSPanel`，圆角 + 窗口阴影；
/// - 放置模式（浮于顶层 / 挂在桌面）与缩放预设；
/// - 自动隐藏 / 强制隐藏状态机与每挂件独立不透明度的叠加；
/// - 复制 / 保存 PNG、键盘快捷键、状态刷新；
/// - `renderOnly` 模式与 `renderDebugPNG(to:)` 离屏渲染自检。
///
/// 注意：自动隐藏的注册 / 注销由 `PinManager` 负责，本类不主动注册。
@MainActor
final class PinWindowController: NSWindowController {

    // MARK: - 对外状态

    /// 挂件展示的图片
    let image: PinnedImage
    /// 关闭回调（PinManager 借此移除自己）；恰好调用一次
    var onClose: ((PinWindowController) -> Void)?
    /// 离屏自检模式：不注册自动隐藏、不真正显示到屏幕
    let renderOnly: Bool

    /// 是否处于自动隐藏（幽灵 / 完全隐藏）状态
    private(set) var isAutoHidden = false
    /// 是否被菜单「隐藏全部贴图」强制隐藏
    private(set) var isForcedHidden = false
    /// 每个挂件独立的用户不透明度（右键菜单 100/80/60/40%）
    private(set) var userAlpha: CGFloat

    /// 内容视图（图片绘制 / 工具栏 / 拖拽缩放 / 右键菜单）
    private(set) var pinContentView: PinContentView!

    /// 放置模式：浮于顶层（默认）/ 挂在桌面
    private(set) var pinPlacement: PinPlacement = .floating

    // MARK: - 内部状态

    private var hasShown = false
    private var didClose = false
    /// 拖拽 / 缩放的嵌套深度；> 0 时自动隐藏不得打断
    private var interactionDepth = 0

    private static let defaultAlphaFloor: CGFloat = 0.2

    // MARK: - 初始化

    init(image: PinnedImage, frame: CGRect, renderOnly: Bool = false) {
        self.image = image
        self.renderOnly = renderOnly
        self.userAlpha = Self.clampedAlpha(AppSettings.shared.defaultPinAlpha)

        let panel = PinPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        configurePanel(panel)

        let content = PinContentView(
            frame: CGRect(origin: .zero, size: frame.size),
            controller: self,
            image: image
        )
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        pinContentView = content

        if renderOnly {
            // 离屏：放到屏幕外，避免出现在用户视野里
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
        }

        // 同步工具栏的放置模式图标（默认浮于顶层）
        content.placementDidChange()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .pinShotSettingsDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 窗口配置

    private func configurePanel(_ panel: PinPanel) {
        let settings = AppSettings.shared
        // isFloatingPanel 会把 level 重置为 floatingWindow，因此先设置浮动再改回自定义层级
        panel.isFloatingPanel = true
        panel.level = PinShotConstants.pinWindowLevel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = settings.showPinShadow
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isRestorable = false
    }

    // MARK: - 对外接口

    var windowFrame: CGRect {
        window?.frame ?? .zero
    }

    /// 显示挂件并淡入到正常可见状态。
    func show() {
        guard !renderOnly else {
            hasShown = true
            return
        }
        guard let window else { return }

        let firstShow = !hasShown
        hasShown = true
        window.orderFrontRegardless()
        window.makeFirstResponder(pinContentView)
        if firstShow {
            window.alphaValue = 0
        }
        // 从截图恢复 / 首次出现：回到正常显示，交给 AutoHideManager 重新开始离开计时
        isAutoHidden = false
        applyVisualState(animated: true)
        // 鼠标可能正好停在选区位置：主动刷新一次工具栏
        pinContentView.refreshToolbarForCurrentMouse()
    }

    /// 关闭挂件，并恰好调用一次 `onClose`。
    func closePin() {
        guard !didClose else { return }
        didClose = true
        window?.orderOut(nil)
        onClose?(self)
    }

    /// 识别当前贴图里的文字，打开结果面板（自动复制能力在面板里）。
    func recognizeText() {
        OCRPanelController.shared.present(image: image, title: "识别文字")
    }

    /// 复制当前图片到系统剪贴板（PNG + TIFF 两种类型）。
    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if let png = pngData() {
            item.setData(png, forType: .png)
        }
        if let tiff = image.nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    /// 保存 PNG。`saveAs == true` 弹 NSSavePanel；否则直接存到桌面。
    func saveImage(saveAs: Bool) {
        // 保存期间暂停自动隐藏（模态循环里定时器仍会跑）
        interactionDepth += 1
        defer { interactionDepth = max(0, interactionDepth - 1) }

        guard let data = pngData() else {
            showAlert(message: "保存失败", info: "无法把图片编码成 PNG。")
            return
        }

        if saveAs {
            let panel = NSSavePanel()
            panel.title = "存储贴图"
            panel.nameFieldStringValue = Self.defaultFileName()
            panel.directoryURL = Self.desktopDirectory
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            writePNG(data, to: url)
        } else {
            let directory = Self.desktopDirectory
            let baseName = "PinShot-\(Self.timestampFormatter.string(from: Date()))"
            let url = Self.uniqueURL(in: directory, baseName: baseName, pathExtension: "png")
            writePNG(data, to: url)
        }
    }

    /// 菜单「隐藏 / 显示全部贴图」；强制隐藏时忽略自动隐藏。
    func setForcedHidden(_ hidden: Bool) {
        guard isForcedHidden != hidden else { return }
        isForcedHidden = hidden
        guard let window else { return }

        if hidden {
            window.orderOut(nil)
        } else {
            isAutoHidden = false
            window.orderFrontRegardless()
            window.makeFirstResponder(pinContentView)
            applyVisualState(animated: true)
            pinContentView.refreshToolbarForCurrentMouse()
        }
    }

    /// 自动隐藏状态机调用：隐藏到幽灵透明度 / 完全隐藏，或恢复到用户不透明度。
    func setAutoHidden(_ hidden: Bool, animated: Bool) {
        guard isAutoHidden != hidden else { return }
        isAutoHidden = hidden
        guard !isForcedHidden else { return }
        applyVisualState(animated: animated)

        // 全屏隐藏 / 点击穿透时鼠标进入不会产生 tracking 事件，
        // 恢复后主动按鼠标位置刷新一次工具栏，避免「已恢复但工具栏不出现」。
        if !hidden {
            pinContentView.refreshToolbarForCurrentMouse()
        }
    }

    /// 设置变化后按当前鼠标位置立即重算自动隐藏状态。
    func refreshAutoHideState() {
        guard !renderOnly, !isForcedHidden, let window else { return }
        let settings = AppSettings.shared
        if !settings.autoHideEnabled || settings.autoHidePaused {
            setAutoHidden(false, animated: true)
            return
        }
        if window.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            setAutoHidden(false, animated: true)
        } else {
            // 延迟 / 透明度等设置可能变了，重新应用目标 alpha
            applyVisualState(animated: true)
        }
    }

    /// 右键菜单「不透明度」：每挂件独立，与自动隐藏 alpha 相乘叠加。
    func setUserAlpha(_ alpha: CGFloat) {
        let clamped = Self.clampedAlpha(alpha)
        guard abs(clamped - userAlpha) > 0.0001 else { return }
        userAlpha = clamped
        applyVisualState(animated: true)
    }

    func bringToFront() {
        window?.orderFrontRegardless()
    }

    // MARK: - 放置模式（浮于顶层 / 挂在桌面）

    /// 切换放置模式。幂等；保持当前 frame / 尺寸；desktop 模式不抢焦点、不参与自动隐藏。
    func setPlacement(_ placement: PinPlacement, animated: Bool) {
        guard pinPlacement != placement else { return }
        pinPlacement = placement
        applyPlacement(animated: animated)
    }

    /// 工具栏按钮 / 右键菜单：在「浮于顶层」与「挂在桌面」之间切换。
    func togglePlacement() {
        setPlacement(pinPlacement == .desktop ? .floating : .desktop, animated: true)
    }

    private func applyPlacement(animated: Bool) {
        guard let window else { return }
        switch pinPlacement {
        case .floating:
            // 恢复浮动面板语义并设置置顶层
            (window as? NSPanel)?.isFloatingPanel = true
            window.level = PinShotConstants.pinWindowLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .desktop:
            // 桌面层级：位于桌面图标之上、普通窗口之下；不跟随全屏应用
            (window as? NSPanel)?.isFloatingPanel = false
            window.level = PinShotConstants.desktopPinWindowLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            // 挂在桌面时始终正常可见：退出自动隐藏 / 点击穿透
            isAutoHidden = false
            if !isForcedHidden {
                applyVisualState(animated: animated)
            }
        }

        // 保持当前 frame / size，仅重新排序；orderFrontRegardless 不会抢焦点
        if !renderOnly, !isForcedHidden, hasShown {
            window.orderFrontRegardless()
        }
        pinContentView.placementDidChange()
        // 若刚恢复为正常可见，主动刷新一次工具栏（鼠标可能正停在挂件上）
        pinContentView.refreshToolbarForCurrentMouse()
        // 让自动隐藏管理器立即按新模式重新计算（desktop 会被跳过）
        AutoHideManager.shared.refreshAll()
    }

    // MARK: - 缩放预设

    /// 以窗口中心为锚点缩放。
    /// - factor > 0：尺寸 = image.pointSize × factor；
    /// - factor <= 0：适合屏幕（visibleFrame 的 80%，不放大超过原图）。
    /// 结果保持宽高比、不小于 40×40，并整体留在所在屏幕可视区域内。
    func setScalePreset(_ factor: CGFloat) {
        guard let window else { return }
        let currentFrame = window.frame
        let visible = visibleFrame(containing: currentFrame)
        let ratio = image.pointSize.width / max(image.pointSize.height, 1)
        let minSize = PinShotConstants.minPinSize

        let proposedWidth: CGFloat
        if factor <= 0 {
            // 适合屏幕：宽 / 高都不超过 visibleFrame 的 80%（小图不放大）
            let maxWidth = visible.width * 0.8
            let maxHeight = visible.height * 0.8
            proposedWidth = min(image.pointSize.width, maxWidth, maxHeight * ratio)
        } else {
            proposedWidth = image.pointSize.width * factor
        }

        var targetSize = CaptureGeometry.resizedSize(
            from: image.pointSize,
            to: CGSize(width: max(proposedWidth, minSize.width), height: 0),
            minSize: minSize
        )
        // 屏幕容纳不下时继续等比缩小
        if targetSize.width > visible.width {
            targetSize = CaptureGeometry.resizedSize(
                from: image.pointSize,
                to: CGSize(width: visible.width, height: 0),
                minSize: minSize
            )
        }
        if targetSize.height > visible.height {
            targetSize = CaptureGeometry.resizedSize(
                from: image.pointSize,
                to: CGSize(width: visible.height * ratio, height: 0),
                minSize: minSize
            )
        }
        targetSize = CGSize(width: targetSize.width.rounded(), height: targetSize.height.rounded())

        // 以当前窗口中心为锚点，并整体收进屏幕可视区域
        var newFrame = CGRect(
            x: currentFrame.midX - targetSize.width / 2,
            y: currentFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        newFrame.origin.x = min(
            max(newFrame.minX, visible.minX),
            max(visible.minX, visible.maxX - newFrame.width)
        )
        newFrame.origin.y = min(
            max(newFrame.minY, visible.minY),
            max(visible.minY, visible.maxY - newFrame.height)
        )
        window.setFrame(newFrame, display: true)
        window.invalidateCursorRects(for: pinContentView)
    }

    /// 与窗口相交面积最大的屏幕的可视区域。
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

    // MARK: - 交互状态（供 AutoHideManager 查询）

    /// 拖拽 / 缩放 / 保存中，自动隐藏不得打断
    var isInteracting: Bool { interactionDepth > 0 }

    func beginInteraction() {
        interactionDepth += 1
        setAutoHidden(false, animated: true)
    }

    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        if interactionDepth == 0 {
            refreshAutoHideState()
        }
    }

    // MARK: - 视觉状态

    /// 目标 alpha = 用户不透明度 × 自动隐藏系数（隐藏时取 ghostAlpha 或 0）。
    private func targetAlpha() -> CGFloat {
        if isForcedHidden { return 0 }
        let hiddenFactor: CGFloat
        if isAutoHidden {
            hiddenFactor = AppSettings.shared.hideEntirely ? 0 : AppSettings.shared.ghostAlpha
        } else {
            hiddenFactor = 1
        }
        return min(max(userAlpha * hiddenFactor, 0), 1)
    }

    private func applyVisualState(animated: Bool) {
        guard let window else { return }
        let settings = AppSettings.shared
        let target = targetAlpha()

        // 隐藏且开启点击穿透时忽略鼠标；恢复时立即恢复可交互
        window.ignoresMouseEvents = (isAutoHidden || isForcedHidden) && settings.clickThroughWhenHidden
        pinContentView.setToolbarSuppressed(isAutoHidden || isForcedHidden)

        guard abs(window.alphaValue - target) > 0.0005 else { return }

        if animated && !renderOnly && window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PinShotConstants.pinAnimationDuration
                window.animator().alphaValue = target
            }
        } else {
            window.alphaValue = target
        }
    }

    // MARK: - 设置变化

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let window else { return }
        window.hasShadow = AppSettings.shared.showPinShadow
        pinContentView.settingsDidChange()
        if isAutoHidden {
            applyVisualState(animated: true)
        }
    }

    // MARK: - 离屏渲染自检

    /// 渲染 contentView（强制工具栏可见、alpha = 1）为 PNG。
    /// 不依赖屏幕录制权限：`renderOnly` 窗口本身就放在屏幕外。
    func renderDebugPNG(to url: URL) -> Bool {
        guard let window, let content = window.contentView else { return false }

        pinContentView.prepareForDebugRendering()
        defer { pinContentView.finishDebugRendering() }

        let savedAlpha = window.alphaValue
        let savedIgnoresMouseEvents = window.ignoresMouseEvents
        let wasVisible = window.isVisible
        let savedOrigin = window.frame.origin
        // 不可见的窗口需要 backing store 才能 cacheDisplay：
        // 临时放到屏幕外再 orderFront，避免离屏自检时窗口在屏幕上闪一下。
        if !wasVisible {
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        }
        defer {
            window.alphaValue = savedAlpha
            window.ignoresMouseEvents = savedIgnoresMouseEvents
            if !wasVisible {
                window.orderOut(nil)
                if !renderOnly {
                    window.setFrameOrigin(savedOrigin)
                }
            }
        }

        window.alphaValue = 1
        window.ignoresMouseEvents = false
        if !wasVisible {
            window.orderFrontRegardless()
        }

        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        guard let representation = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            return false
        }
        content.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[PinShot] 渲染 PNG 失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - PNG / 保存辅助

    private func pngData() -> Data? {
        let representation = NSBitmapImageRep(cgImage: image.cgImage)
        representation.size = image.pointSize
        return representation.representation(using: .png, properties: [:])
    }

    private func writePNG(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            NSLog("[PinShot] 已保存贴图: \(url.path)")
        } catch {
            NSLog("[PinShot] 保存贴图失败: \(error.localizedDescription)")
            showAlert(message: "保存失败", info: error.localizedDescription)
        }
    }

    private func showAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func defaultFileName() -> String {
        "PinShot-\(timestampFormatter.string(from: Date())).png"
    }

    private static func clampedAlpha(_ value: CGFloat) -> CGFloat {
        min(max(value, defaultAlphaFloor), 1)
    }

    private static func uniqueURL(in directory: URL, baseName: String, pathExtension: String) -> URL {
        var url = directory.appendingPathComponent("\(baseName).\(pathExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)-\(index).\(pathExtension)")
            index += 1
        }
        return url
    }
}

// MARK: - 面板

/// 无边框置顶面板：可成为 key（接收 ⌘C/⌘S/⌘W/Esc/方向键），但不成为 main。
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
