import AppKit

/// 离屏渲染 UI 设计稿（开发用）：不显示窗口、不需要屏幕录制权限。
/// 用法：PinShot --render-ui build/ui
@MainActor
enum UIRenderTest {

    static func run(outputDirectory: String) -> Bool {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("❌ 无法创建输出目录: \(error)")
            return false
        }

        var allOK = true
        var outputs: [URL] = []

        // 设计稿用一套「展示状态」：自动隐藏开启，控件全部可交互；
        // 渲染完成后恢复用户真实设置。
        let appSettings = AppSettings.shared
        let savedAutoHide = appSettings.autoHideEnabled
        let savedPaused = appSettings.autoHidePaused
        let savedEntirely = appSettings.hideEntirely
        let savedClickThrough = appSettings.clickThroughWhenHidden
        let savedDelay = appSettings.autoHideDelay
        let savedGhost = appSettings.ghostAlpha
        let savedBorder = appSettings.showPinBorder
        let savedShadow = appSettings.showPinShadow
        appSettings.autoHideEnabled = true
        appSettings.autoHidePaused = false
        appSettings.hideEntirely = false
        appSettings.clickThroughWhenHidden = true
        appSettings.autoHideDelay = 2.0
        appSettings.ghostAlpha = 0.12
        appSettings.showPinBorder = true
        appSettings.showPinShadow = true
        defer {
            appSettings.autoHideEnabled = savedAutoHide
            appSettings.autoHidePaused = savedPaused
            appSettings.hideEntirely = savedEntirely
            appSettings.clickThroughWhenHidden = savedClickThrough
            appSettings.autoHideDelay = savedDelay
            appSettings.ghostAlpha = savedGhost
            appSettings.showPinBorder = savedBorder
            appSettings.showPinShadow = savedShadow
        }

        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        for (name, appearanceName) in appearances {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }

            // 首次引导
            let onboarding = OnboardingWindowController()
            if let window = onboarding.window {
                let url = directory.appendingPathComponent("ui-onboarding-\(name).png")
                if render(window: window, appearance: appearance, to: url) { outputs.append(url) } else { allOK = false }
            }

            // 权限引导
            let permission = PermissionGuideWindowController()
            if let window = permission.window {
                let url = directory.appendingPathComponent("ui-permission-\(name).png")
                if render(window: window, appearance: appearance, to: url) { outputs.append(url) } else { allOK = false }
            }

            // 标注编辑器（合成截图 + 示例笔画）
            let annotationImage = makeAnnotationSampleImage()
            let annotationEditor = AnnotationEditorController(image: annotationImage) { _ in }
            annotationEditor.debugApplySampleAnnotations()
            if let view = annotationEditor.debugPrepareForRendering(appearance: appearance) {
                let url = directory.appendingPathComponent("ui-annotation-\(name).png")
                if render(view: view, to: url) { outputs.append(url) } else { allOK = false }
            }

            // 设置窗口：4 个导航页
            let settings = SettingsWindowController.shared
            settings.debugPrepareForRendering(appearance: appearance)
            for pane in SettingsWindowController.Pane.allCases {
                settings.debugSelectPane(pane)
                guard let window = settings.window else { continue }
                let paneName = String(describing: pane)
                let url = directory.appendingPathComponent("ui-settings-\(name)-\(paneName).png")
                if render(window: window, appearance: appearance, to: url) { outputs.append(url) } else { allOK = false }
            }
        }

        print("\n\(allOK ? "✅" : "❌") UI 渲染\(allOK ? "完成" : "失败")，产物：")
        for url in outputs { print("   \(url.path)") }
        return allOK
    }

    private static func makeAnnotationSampleImage() -> PinnedImage {
        let snapshot = RenderSelfTest.makeDesktopSnapshot(pointSize: CGSize(width: 720, height: 460), scale: 2)
        let selection = CGRect(x: 90, y: 70, width: 560, height: 340)
        return CaptureGeometry.pinImage(from: snapshot, selection: selection)
            ?? PinnedImage(cgImage: snapshot.image, pointSize: snapshot.pointSize)
    }

    // MARK: - 渲染工具

    private static func render(view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 1, view.bounds.height > 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            print("   渲染 \(url.lastPathComponent) \(representation.pixelsWide)×\(representation.pixelsHigh)")
            return true
        } catch {
            return false
        }
    }

    private static func render(window: NSWindow, appearance: NSAppearance, to url: URL) -> Bool {
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        let savedOrigin = window.frame.origin
        let wasVisible = window.isVisible
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        if !wasVisible { window.orderFrontRegardless() }
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        defer {
            if !wasVisible { window.orderOut(nil) }
            window.setFrameOrigin(savedOrigin)
        }

        guard view.bounds.width > 1, view.bounds.height > 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            print("   渲染 \(url.lastPathComponent) \(representation.pixelsWide)×\(representation.pixelsHigh)")
            return true
        } catch {
            print("   ❌ 写入失败 \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
