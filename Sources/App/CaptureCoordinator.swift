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
