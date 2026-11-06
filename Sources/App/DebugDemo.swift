import AppKit

/// 仅用于开发/验收的调试启动参数（正常启动不触发）：
/// - `--demo-pin`     抓一张屏幕截图并创建一个贴图挂件（用于真机目检/自动隐藏验收）
/// - `--settings`     启动后打开设置窗口
/// - `--quit-after N` 启动 N 秒后自动退出（自动化验收用）
@MainActor
enum DebugDemo {

    private static var overlay: SelectionOverlayController?
    private static var annotationEditor: AnnotationEditorController?

    static func handleLaunchArguments() {
        let arguments = CommandLine.arguments

        // 调试：强制深色外观（UI 截图用）
        if arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // 调试：清除当前 App 的屏幕录制授权记录（解决重建后旧授权条目失效）
        if arguments.contains("--reset-screen-permission") {
            let ok = ScreenCapturer.resetScreenRecordingPermission()
            NSLog("[PinShot] reset screen recording permission: \(ok)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
            return
        }

        if arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                SettingsWindowController.shared.show()
            }
        }

        if arguments.contains("--dump-screens") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                dumpScreens()
            }
        }

        if arguments.contains("--demo-clipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
                let snapshot = RenderSelfTest.makeDesktopSnapshot(pointSize: frame.size, scale: 2)
                let selection = CGRect(x: 240, y: 180, width: 620, height: 420)
                if let image = CaptureGeometry.pinImage(from: snapshot, selection: selection),
                   let data = CaptureCoordinator.pngData(from: image.cgImage) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(data, forType: .png)
                    CaptureCoordinator.shared.beginFromClipboard()
                    NSLog("[PinShotDemo] clipboard image prepared")
                }
            }
        }

        if arguments.contains("--demo-annotate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                presentDemoAnnotation()
            }
        }

        if arguments.contains("--demo-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                presentDemoOverlay()
            }
        }

        if arguments.contains("--demo-pin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                createDemoPin()
            }
        }

        if let index = arguments.firstIndex(of: "--quit-after"),
           index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds)) {
                NSApp.terminate(nil)
            }
        }
    }

    /// 用合成截图打开标注编辑器（无需屏幕录制权限），用于真机目检标注工具。
    private static func presentDemoAnnotation() {
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
        // 合成桌面的 frame 固定从 (0,0) 开始，选区坐标也要用它自己的局部坐标系
        let snapshot = RenderSelfTest.makeDesktopSnapshot(pointSize: screenFrame.size, scale: 2)
        let size = CGSize(width: 640, height: 420)
        let selection = CGRect(
            x: (screenFrame.width - size.width) / 2,
            y: (screenFrame.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        guard let image = CaptureGeometry.pinImage(from: snapshot, selection: selection) else {
            NSLog("[PinShotDemo] annotation crop failed")
            return
        }
        let globalRect = CGRect(
            x: screenFrame.minX + selection.minX,
            y: screenFrame.minY + selection.minY,
            width: selection.width,
            height: selection.height
        )
        let editor = AnnotationEditorController(image: image) { outcome in
            annotationEditor = nil
            switch outcome {
            case .cancelled:
                NSLog("[PinShotDemo] annotation cancelled")
            case .completed(let annotated, let action):
                NSLog("[PinShotDemo] annotation completed action=\(action) size=\(annotated.pointSize)")
                switch action {
                case .finish:
                    PinManager.shared.addPin(annotated, at: globalRect)
                case .copy:
                    CaptureCoordinator.copyToPasteboard(annotated)
                case .save:
                    CaptureCoordinator.saveImage(annotated)
                }
            }
        }
        annotationEditor = editor
        editor.present()
    }

    /// 抓取冻结帧并展示选区覆盖层（不依赖鼠标/辅助功能），用于目检遮罩与提示。
    private static func presentDemoOverlay() {
        Task { @MainActor in
            switch await ScreenCapturer().captureAllScreens() {
            case .failure(let error):
                NSLog("[PinShotDemo] overlay capture failed: \(error.localizedDescription)")
            case .success(let snapshots):
                let controller = SelectionOverlayController(snapshots: snapshots) { outcome in
                    switch outcome {
                    case .cancelled: NSLog("[PinShotDemo] overlay cancelled")
                    case .selected(_, let rect): NSLog("[PinShotDemo] overlay selected \(rect)")
                    }
                }
                overlay = controller
                controller.present()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    controller.dismiss()
                    NSLog("[PinShotDemo] overlay dismissed")
                }
            }
        }
    }

    /// 打印 NSScreen / 截图结果并落盘，用于核对多屏映射。
    private static func dumpScreens() {
        let arguments = CommandLine.arguments
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            NSLog("[PinShotDump] NSScreen name=\(screen.localizedName) frame=\(screen.frame) scale=\(screen.backingScaleFactor) id=\(number?.uint32Value ?? 0)")
        }
        NSLog("[PinShotDump] main=\(NSScreen.main?.localizedName ?? "nil") mouse=\(NSEvent.mouseLocation)")
        Task { @MainActor in
            switch await ScreenCapturer().captureAllScreens() {
            case .failure(let error):
                NSLog("[PinShotDump] capture failed: \(error.localizedDescription)")
            case .success(let snapshots):
                for snapshot in snapshots {
                    NSLog("[PinShotDump] snapshot id=\(snapshot.displayID) frame=\(snapshot.frame) scale=\(snapshot.scale) pixels=\(snapshot.pixelSize)")
                    let rep = NSBitmapImageRep(cgImage: snapshot.image)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let url = URL(fileURLWithPath: "/tmp/dump-screen-id\(snapshot.displayID).png")
                        try? data.write(to: url)
                        NSLog("[PinShotDump] wrote \(url.path)")
                    }
                }
            }
            if arguments.contains("--quit-after") == false {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    private static func createDemoPin() {
        Task { @MainActor in
            let snapshot: ScreenSnapshot
            let source: String

            switch await ScreenCapturer().captureAllScreens() {
            case .success(let snapshots):
                guard let main = snapshots.first(where: { $0.frame.origin == .zero }) ?? snapshots.first else {
                    NSLog("[PinShotDemo] no snapshot")
                    return
                }
                snapshot = main
                source = "real"
            case .failure(let error):
                NSLog("[PinShotDemo] 截图失败，使用合成桌面: \(error.localizedDescription)")
                let size = NSScreen.main?.frame.size ?? CGSize(width: 1470, height: 956)
                snapshot = RenderSelfTest.makeDesktopSnapshot(pointSize: size, scale: 2)
                source = "synthetic"
            }

            let size = CGSize(width: 460, height: 300)
            let screen = snapshot.frame
            let mouse = NSEvent.mouseLocation

            // 选一个鼠标不在其中的位置，保证自动隐藏能正常触发
            let candidates: [CGPoint] = [
                CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2),
                CGPoint(x: screen.maxX - size.width - 80, y: screen.maxY - size.height - 120),
                CGPoint(x: screen.minX + 80, y: screen.minY + 120)
            ]
            let origin = candidates.first { candidate in
                !CGRect(origin: candidate, size: size).insetBy(dx: -40, dy: -40).contains(mouse)
            } ?? candidates[0]

            let selection = CGRect(origin: origin, size: size)
            guard let image = CaptureGeometry.pinImage(from: snapshot, selection: selection) else {
                NSLog("[PinShotDemo] crop failed")
                return
            }
            let globalRect = CaptureGeometry.globalRect(forSelection: selection, in: snapshot)
            let pin = PinManager.shared.addPin(image, at: globalRect)
            NSLog("[PinShotDemo] source=\(source) pin=\(pin.windowFrame) mouse=\(mouse)")

            // 验收用：定时打印自动隐藏状态
            for delay in [1.0, 2.5, 4.0, 5.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let settings = AppSettings.shared
                    NSLog("[PinShotDemo] t=\(delay) hidden=\(pin.isAutoHidden) alpha=\(pin.window?.alphaValue ?? -1) visible=\(pin.window?.isVisible ?? false) ignores=\(pin.window?.ignoresMouseEvents ?? false) autoHideEnabled=\(settings.autoHideEnabled) paused=\(settings.autoHidePaused) delay=\(settings.autoHideDelay) mouse=\(NSEvent.mouseLocation)")
                }
            }
        }
    }
}
