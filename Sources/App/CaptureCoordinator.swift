import AppKit
import UniformTypeIdentifiers
import ImageIO

/// 编排一次截图：隐藏已有贴图 → 抓屏 → 选区 → 贴图 / 复制 → 恢复贴图与前台应用。
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    enum Mode {
        case pin
        case clipboard
    }

    private var isCapturing = false
    private var overlay: SelectionOverlayController?
    private var annotationEditor: AnnotationEditorController?
    private var clipboardEditor: AnnotationEditorController?
    private var previousFrontmostApp: NSRunningApplication?
    private var pendingDelay: DispatchWorkItem?
    private var windowCandidates: [WindowCandidate] = []
    private var scrollController: ScrollingCaptureController?
    private var gifRecorder: GIFRecorderController?

    private enum LastSelectionStore {
        static let displayIDKey = "lastSelection.displayID"
        static let rectKey = "lastSelection.rect"

        static func save(displayID: CGDirectDisplayID, rect: CGRect) {
            let defaults = UserDefaults.standard
            defaults.set(Int(displayID), forKey: displayIDKey)
            defaults.set([
                "x": rect.origin.x, "y": rect.origin.y,
                "width": rect.width, "height": rect.height
            ], forKey: rectKey)
        }

        static func load() -> (CGDirectDisplayID, CGRect)? {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: displayIDKey) != nil,
                  let dict = defaults.dictionary(forKey: rectKey),
                  let x = dict["x"] as? Double, let y = dict["y"] as? Double,
                  let w = dict["width"] as? Double, let h = dict["height"] as? Double,
                  w > 1, h > 1 else { return nil }
            let displayID = CGDirectDisplayID(defaults.integer(forKey: displayIDKey))
            return (displayID, CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private init() {}

    var isBusy: Bool { isCapturing }

    // MARK: - 入口

    func begin(mode: Mode) {
        guard !isCapturing else { return }
        isCapturing = true
        NSLog("[PinShot] capture begin mode=\(mode == .pin ? "pin" : "clipboard")")

        // 1. 记录前台应用，隐藏已有贴图
        //    注意：不先用 CGPreflight 短路，先真实抓一次；预检缓存可能滞后，
        //    授权后无需重启也可能直接可用。失败时再弹权限引导。
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        // 3. 等合成器把贴图移出画面后再抓屏
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            let result = await ScreenCapturer().captureAllScreens()
            switch result {
            case .success(let snapshots):
                self.presentSelection(with: snapshots, mode: mode)
            case .failure(let error):
                NSLog("[PinShot] capture failed: \(error.localizedDescription)")
                self.abortCapture()
                self.handleCaptureFailure(error, mode: mode)
            }
        }
    }

    // MARK: - Shottr 风格截图模式

    var hasLastSelection: Bool { LastSelectionStore.load() != nil }

    /// 全屏截图：抓取鼠标所在显示器的完整画面，进入标注编辑器。
    func beginFullScreen(mode: Mode = .pin) {
        guard !isCapturing else { return }
        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            let result = await ScreenCapturer().captureAllScreens()
            switch result {
            case .success(let snapshots):
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
                let snapshot = snapshots.first(where: { $0.frame == screen?.frame }) ?? snapshots.first
                guard let snapshot,
                      let image = CaptureGeometry.pinImage(
                        from: snapshot,
                        selection: CGRect(origin: .zero, size: snapshot.frame.size),
                        minPixelSize: 2) else {
                    self.finishCapture()
                    return
                }
                self.presentAnnotationEditor(image: image, screenRect: snapshot.frame, mode: mode)
            case .failure(let error):
                self.abortCapture()
                self.handleCaptureFailure(error, mode: mode)
            }
        }
    }

    /// 延时截图：给用户留出布置窗口/菜单的时间，到点后走普通框选流程。
    func beginDelayed(seconds: TimeInterval, mode: Mode = .pin) {
        guard !isCapturing else { return }
        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDelay = nil
            PinManager.shared.hideAllForCapture()
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
                let result = await ScreenCapturer().captureAllScreens()
                switch result {
                case .success(let snapshots):
                    self.presentSelection(with: snapshots, mode: mode)
                case .failure(let error):
                    self.abortCapture()
                    self.handleCaptureFailure(error, mode: mode)
                }
            }
        }
        pendingDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    /// 窗口截图：弹出窗口选择菜单，选中后抓取整个窗口。
    func beginWindowCapture(mode: Mode = .pin) {
        guard !isCapturing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = await WindowCapturer.listWindows()
            guard !candidates.isEmpty else {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "没有可截图的窗口"
                alert.informativeText = "请先打开一个普通应用窗口（PinShot 自己的窗口会被排除）。"
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            self.windowCandidates = candidates
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "窗口截图"
            alert.informativeText = "选择要截图的窗口："
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28), pullsDown: false)
            for candidate in candidates {
                let rawTitle = candidate.title.count > 56 ? String(candidate.title.prefix(55)) + "…" : candidate.title
                let title = "\(candidate.appName) — \(rawTitle)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = candidate.icon
                popup.menu?.addItem(item)
            }
            alert.accessoryView = popup
            alert.addButton(withTitle: "截图")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            let index = popup.indexOfSelectedItem
            guard index >= 0, index < self.windowCandidates.count else { return }
            self.captureWindow(self.windowCandidates[index])
        }
    }

    private func captureWindow(_ candidate: WindowCandidate) {
        guard !isCapturing else { return }
        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            do {
                let captured = try await WindowCapturer.capture(candidate)
                let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? NSScreen.main
                let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
                let maxSize = CGSize(width: visible.width * 0.7, height: visible.height * 0.7)
                let scale = min(
                    1,
                    maxSize.width / max(captured.image.pointSize.width, 1),
                    maxSize.height / max(captured.image.pointSize.height, 1)
                )
                let displaySize = CGSize(
                    width: max(1, (captured.image.pointSize.width * scale).rounded()),
                    height: max(1, (captured.image.pointSize.height * scale).rounded())
                )
                let image = PinnedImage(cgImage: captured.image.cgImage, pointSize: displaySize)
                let frame = CGRect(
                    x: visible.midX - displaySize.width / 2,
                    y: visible.midY - displaySize.height / 2,
                    width: displaySize.width,
                    height: displaySize.height
                )
                self.presentAnnotationEditor(image: image, screenRect: frame, mode: .pin)
            } catch {
                self.finishCapture()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "窗口截图失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// 滚动截图：框选区域后自动/手动滚动并拼接成长图。
    func beginScrollCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            let result = await ScreenCapturer().captureAllScreens()
            switch result {
            case .success(let snapshots):
                self.presentScrollSelection(with: snapshots)
            case .failure(let error):
                self.abortCapture()
                self.handleCaptureFailure(error, mode: .pin)
            }
        }
    }

    private func presentScrollSelection(with snapshots: [ScreenSnapshot]) {
        let controller = SelectionOverlayController(snapshots: snapshots) { [weak self] outcome in
            guard let self else { return }
            self.overlay = nil
            switch outcome {
            case .cancelled:
                self.finishCapture()
            case .selected(let snapshot, let rect):
                let globalRect = CaptureGeometry.globalRect(forSelection: rect, in: snapshot)
                let scroller = ScrollingCaptureController(
                    snapshot: snapshot,
                    selection: rect,
                    mode: .pin,
                    onComplete: { [weak self] image, frame in
                        guard let self else { return }
                        self.scrollController = nil
                        self.presentAnnotationEditor(image: image, screenRect: frame, mode: .pin)
                    },
                    onCancel: { [weak self] in
                        guard let self else { return }
                        self.scrollController = nil
                        self.finishCapture()
                    }
                )
                self.scrollController = scroller
                scroller.start()
                NSLog("[PinShot] scroll capture started rect=\(globalRect)")
            }
        }
        overlay = controller
        controller.present()
    }

    /// 选区 GIF 录制：框选后开始 10fps 录制，HUD 停止（Esc 取消），结束后保存 GIF。
    func beginGIFRecording() {
        guard !isCapturing else { return }
        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            let result = await ScreenCapturer().captureAllScreens()
            switch result {
            case .success(let snapshots):
                self.presentGIFSelection(with: snapshots)
            case .failure(let error):
                self.abortCapture()
                self.handleCaptureFailure(error, mode: .pin)
            }
        }
    }

    private func presentGIFSelection(with snapshots: [ScreenSnapshot]) {
        let controller = SelectionOverlayController(snapshots: snapshots) { [weak self] outcome in
            guard let self else { return }
            self.overlay = nil
            switch outcome {
            case .cancelled:
                self.finishCapture()
            case .selected(let snapshot, let rect):
                let recorder = GIFRecorderController(
                    snapshot: snapshot,
                    selection: rect,
                    onFinish: { [weak self] url in
                        guard let self else { return }
                        self.gifRecorder = nil
                        NSLog("[PinShot] GIF recording finished url=\(url?.path ?? "nil")")
                        self.finishCapture()
                    }
                )
                self.gifRecorder = recorder
                recorder.start()
            }
        }
        overlay = controller
        controller.present()
    }

    /// 重复上一次的框选区域。
    func repeatLastSelection() {
        guard !isCapturing else { return }
        guard let stored = LastSelectionStore.load() else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "还没有可重复的区域"
            alert.informativeText = "先用「截图并贴图」框选一次，之后就可以重复这个区域。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        PinManager.shared.hideAllForCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinShotConstants.hideBeforeCaptureDelay * 1_000_000_000))
            let result = await ScreenCapturer().captureAllScreens()
            switch result {
            case .success(let snapshots):
                let snapshot = snapshots.first(where: { $0.displayID == stored.0 })
                    ?? snapshots.first(where: { $0.frame.contains(CGPoint(x: stored.1.midX, y: stored.1.midY)) })
                    ?? snapshots.first
                guard let snapshot,
                      let image = CaptureGeometry.pinImage(from: snapshot, selection: stored.1, minPixelSize: 2) else {
                    self.finishCapture()
                    return
                }
                let globalRect = CaptureGeometry.globalRect(forSelection: stored.1, in: snapshot)
                self.presentAnnotationEditor(image: image, screenRect: globalRect, mode: .pin)
            case .failure(let error):
                self.abortCapture()
                self.handleCaptureFailure(error, mode: .pin)
            }
        }
    }

    // MARK: - 从剪贴板贴图

    /// 兜底入口：系统截图（⇧⌃⌘4 复制到剪贴板）后，用 PinShot 贴图/标注。
    /// 不依赖屏幕录制权限，因此在授权异常时依然可用。
    func beginFromClipboard() {
        guard !isCapturing else { return }
        guard let source = Self.imageFromPasteboard() else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "剪贴板里没有图片"
            alert.informativeText = "先用系统截图把图片放进剪贴板：\n⇧⌃⌘4（框选并复制）或 ⇧⌃⌘3（全屏并复制），再点「从剪贴板贴图」。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        isCapturing = true
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let maxSize = CGSize(width: visible.width * 0.7, height: visible.height * 0.7)
        let scale = min(1, maxSize.width / source.pointSize.width, maxSize.height / source.pointSize.height)
        let displaySize = CGSize(
            width: max(1, (source.pointSize.width * scale).rounded()),
            height: max(1, (source.pointSize.height * scale).rounded())
        )
        let image = PinnedImage(cgImage: source.cgImage, pointSize: displaySize)
        let frame = CGRect(
            x: visible.midX - displaySize.width / 2,
            y: visible.midY - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        )

        let editor = AnnotationEditorController(image: image) { [weak self] outcome in
            guard let self else { return }
            self.clipboardEditor = nil
            switch outcome {
            case .cancelled:
                break
            case .completed(let annotated, let action):
                switch action {
                case .finish:
                    PinManager.shared.addPin(annotated, at: frame)
                case .copy:
                    Self.copyToPasteboard(annotated)
                case .save:
                    Self.saveImage(annotated)
                }
            }
            self.isCapturing = false
            if let app = self.previousFrontmostApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.activate(options: [])
            }
            self.previousFrontmostApp = nil
        }
        clipboardEditor = editor
        editor.present()
    }

    /// 从剪贴板读取图片，优先 PNG/TIFF，保留原始像素。
    static func imageFromPasteboard() -> PinnedImage? {
        let pasteboard = NSPasteboard.general

        // 优先 NSImage：能拿到系统写入的 Retina 点尺寸
        if let nsImage = NSImage(pasteboard: pasteboard) {
            var proposed = NSRect(origin: .zero, size: nsImage.size)
            if let cg = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
               cg.width > 1, cg.height > 1 {
                let pointSize = nsImage.size.width > 1 ? nsImage.size : CGSize(width: cg.width, height: cg.height)
                return PinnedImage(cgImage: cg, pointSize: pointSize)
            }
        }

        if let data = pasteboard.data(forType: .png),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return PinnedImage(cgImage: cg, pointSize: CGSize(width: cg.width, height: cg.height))
        }
        if let data = pasteboard.data(forType: .tiff),
           let nsImage = NSImage(data: data) {
            var proposed = NSRect(origin: .zero, size: nsImage.size)
            if let cg = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
                return PinnedImage(cgImage: cg, pointSize: nsImage.size)
            }
        }
        return nil
    }

    // MARK: - 选区

    private func presentSelection(with snapshots: [ScreenSnapshot], mode: Mode) {
        NSLog("[PinShot] present selection over \(snapshots.count) screen(s)")
        let controller = SelectionOverlayController(snapshots: snapshots) { [weak self] outcome in
            guard let self else { return }
            self.overlay = nil
            switch outcome {
            case .cancelled:
                self.finishCapture()
            case .selected(let snapshot, let rect):
                NSLog("[PinShot] selected rect=\(rect) on screen=\(snapshot.frame)")
                guard let image = CaptureGeometry.pinImage(from: snapshot, selection: rect, minPixelSize: 2) else {
                    self.finishCapture()
                    return
                }
                let globalRect = CaptureGeometry.globalRect(forSelection: rect, in: snapshot)
                LastSelectionStore.save(displayID: snapshot.displayID, rect: rect)
                self.presentAnnotationEditor(image: image, screenRect: globalRect, mode: mode)
            }
        }
        overlay = controller
        controller.present()
    }

    // MARK: - 标注编辑器

    private func presentAnnotationEditor(image: PinnedImage, screenRect: CGRect, mode: Mode) {
        let editor = AnnotationEditorController(image: image) { [weak self] outcome in
            guard let self else { return }
            self.annotationEditor = nil
            switch outcome {
            case .cancelled:
                break
            case .completed(let annotated, let action):
                switch action {
                case .finish:
                    switch mode {
                    case .pin:
                        PinManager.shared.addPin(annotated, at: screenRect)
                    case .clipboard:
                        Self.copyToPasteboard(annotated)
                    }
                case .copy:
                    Self.copyToPasteboard(annotated)
                case .save:
                    Self.saveImage(annotated)
                }
            }
            self.finishCapture()
        }
        annotationEditor = editor
        editor.present()
    }

    private func abortCapture() {
        overlay?.dismiss()
        overlay = nil
        finishCapture()
    }

    private func finishCapture() {
        NSLog("[PinShot] capture finished, pins=\(PinManager.shared.pinCount)")
        PinManager.shared.restoreAfterCapture()
        isCapturing = false
        // 把焦点还给截图前的应用
        if let app = previousFrontmostApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(options: [])
        }
        previousFrontmostApp = nil
    }

    // MARK: - 错误 / 权限引导

    private func handleCaptureFailure(_ error: ScreenCaptureError, mode: Mode) {
        if case .permissionDenied = error {
            Self.showPermissionGuide(force: true) { [weak self] in
                self?.begin(mode: mode)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = [error.errorDescription, error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "打开屏幕录制设置")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            ScreenCapturer.openScreenRecordingSettings()
        }
    }

    /// 菜单 / 首次截图失败入口：显示品牌化权限引导。
    /// force=false 且已有权限时不打扰用户。
    static func showPermissionGuide(force: Bool = false, onAuthorized: (() -> Void)? = nil) {
        if !force && ScreenCapturer.hasScreenRecordingPermission() { return }
        PermissionGuideWindowController.shared.present(onAuthorized: onAuthorized)
    }

    // MARK: - 剪贴板

    static func copyToPasteboard(_ image: PinnedImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if let data = Self.pngData(from: image.cgImage) {
            item.setData(data, forType: .png)
        }
        if let tiff = image.nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// 标注后「保存」：NSSavePanel，默认桌面 + PinShot-时间戳.png。
    @MainActor
    static func saveImage(_ image: PinnedImage) {
        guard let data = pngData(from: image.cgImage) else { return }
        let panel = NSSavePanel()
        panel.title = "存储截图"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "PinShot-\(formatter.string(from: Date())).png"
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSLog("[PinShot] 已保存标注截图: \(url.path)")
        } catch {
            NSLog("[PinShot] 保存标注截图失败: \(error.localizedDescription)")
        }
    }
}
