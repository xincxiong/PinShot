import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 选区 GIF 录制：选区截图后按 10fps 抓帧，增量写入 GIF；HUD 可停止，Esc 取消。
@MainActor
final class GIFRecorderController {

    private let snapshot: ScreenSnapshot
    private let selection: CGRect
    private let maxDuration: TimeInterval
    private let maxFrames: Int
    private let frameInterval: TimeInterval = 0.10
    private let onFinish: (URL?) -> Void

    private var hud: GIFHUDWindow?
    private var destination: CGImageDestination?
    private var tempURL: URL?
    private var task: Task<Void, Never>?
    private var startedAt = Date()
    private var lastFrameAt: Date?
    private var frameCount = 0
    private var stopped = false
    private var finalizing = false
    private var didFinish = false
    private var keyMonitor: Any?

    init(
        snapshot: ScreenSnapshot,
        selection: CGRect,
        maxDuration: TimeInterval = 15,
        maxFrames: Int = 150,
        onFinish: @escaping (URL?) -> Void
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.maxDuration = maxDuration
        self.maxFrames = maxFrames
        self.onFinish = onFinish
    }

    func start() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinshot-\(UUID().uuidString).gif")
        tempURL = temp
        guard let dest = CGImageDestinationCreateWithURL(
            temp as CFURL,
            UTType.gif.identifier as CFString,
            0, // 帧数未知；0 表示由 CGImageDestination 动态增长
            nil
        ) else {
            finish(nil)
            return
        }
        destination = dest
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        startedAt = Date()
        showHUD()
        installKeyMonitor()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            // 让 HUD / 选区覆盖层先稳定
            try? await Task.sleep(nanoseconds: 220_000_000)
            while !self.stopped {
                if Date().timeIntervalSince(self.startedAt) >= self.maxDuration || self.frameCount >= self.maxFrames {
                    self.stopRecording()
                    break
                }

                let result = await ScreenCapturer().captureAllScreens()
                if self.stopped { break }
                if case .success(let snapshots) = result,
                   let current = snapshots.first(where: { $0.displayID == self.snapshot.displayID })
                    ?? snapshots.first(where: { $0.frame == self.snapshot.frame })
                    ?? snapshots.first,
                   let image = CaptureGeometry.pinImage(from: current, selection: self.selection, minPixelSize: 2) {
                    self.appendFrame(image.cgImage)
                }

                // 实际帧间隔按时间戳写入 GIF，避免抓帧慢时播放变快。
                let sleep = max(0.02, self.frameInterval - Date().timeIntervalSince(self.lastFrameAt ?? Date()))
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            }
            self.finalizeRecording()
        }
    }

    func stopRecording() {
        guard !stopped else { return }
        stopped = true
        hud?.setRecording(false, frameCount: frameCount, duration: Date().timeIntervalSince(startedAt))
    }

    func cancelRecording() {
        guard !stopped else { return }
        stopped = true
        finalizing = true
        task?.cancel()
        removeKeyMonitor()
        hud?.close()
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        finish(nil)
    }

    // MARK: - 帧 / 编码

    private func appendFrame(_ cgImage: CGImage) {
        guard let destination, let scaled = Self.scaled(cgImage, maxDimension: 900) else { return }
        let now = Date()
        let delay = max(0.05, min(0.5, now.timeIntervalSince(lastFrameAt ?? now)))
        lastFrameAt = now
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        frameCount += 1
        hud?.setRecording(true, frameCount: frameCount, duration: now.timeIntervalSince(startedAt))
    }

    private static func scaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        guard scale < 0.999 else { return image }
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private func finalizeRecording() {
        guard !finalizing, !didFinish else { return }
        finalizing = true
        removeKeyMonitor()
        hud?.close()
        hud = nil

        guard let destination, frameCount > 0 else {
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            finish(nil)
            return
        }
        guard CGImageDestinationFinalize(destination) else {
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            finish(nil)
            return
        }
        guard let tempURL else { finish(nil); return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "PinShot-\(formatter.string(from: Date())).gif"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let destinationURL = desktop.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            NSLog("[PinShot] GIF saved to \(destinationURL.path)")
            ToastPresenter.shared.show("GIF 已保存到桌面 · \(filename)")
            finish(destinationURL)
        } catch {
            NSLog("[PinShot] GIF save failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            let alert = NSAlert()
            alert.messageText = "GIF 保存失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            finish(nil)
        }
    }

    private func finish(_ url: URL?) {
        guard !didFinish else { return }
        didFinish = true
        task = nil
        onFinish(url)
    }

    // MARK: - HUD

    private func showHUD() {
        let panel = GIFHUDWindow()
        panel.onStop = { [weak self] in self?.stopRecording() }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: 320, height: 72)
        // 尽量放在选区外：依次尝试上方、下方、右侧、左侧
        let globalSelection = CaptureGeometry.globalRect(forSelection: selection, in: snapshot)
        let candidates = [
            CGPoint(x: globalSelection.midX - size.width / 2, y: globalSelection.maxY + 16),
            CGPoint(x: globalSelection.midX - size.width / 2, y: globalSelection.minY - size.height - 16),
            CGPoint(x: globalSelection.maxX + 16, y: globalSelection.midY - size.height / 2),
            CGPoint(x: globalSelection.minX - size.width - 16, y: globalSelection.midY - size.height / 2)
        ]
        var origin = candidates.first ?? CGPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        if candidates.contains(where: { visible.contains(CGRect(origin: $0, size: size)) }) {
            origin = candidates.first(where: { visible.contains(CGRect(origin: $0, size: size)) }) ?? origin
        }
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hud = panel
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.hud?.isVisible == true else { return event }
            if event.keyCode == 53 {
                self.cancelRecording()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.stopRecording()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - HUD 面板

@MainActor
private final class GIFHUDWindow: NSPanel {
    var onStop: (() -> Void)?

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "录制 GIF")
    private let statusLabel = NSTextField(labelWithString: "00:00 · 0 帧")
    private let stopButton = PinButton(title: "停止", style: .primary)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 0.96).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.frame = NSRect(x: 18, y: 32, width: 8, height: 8)

        titleLabel.font = PSTheme.text(12, weight: .semibold)
        titleLabel.textColor = NSColor.white
        titleLabel.frame = NSRect(x: 34, y: 34, width: 180, height: 18)
        statusLabel.font = PSTheme.text(11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel.frame = NSRect(x: 18, y: 14, width: 190, height: 18)

        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.buttonFont = PSTheme.text(11.5, weight: .semibold)
        stopButton.contentInset = NSSize(width: 14, height: 6)
        stopButton.frame = NSRect(x: 244, y: 22, width: 62, height: 28)

        bg.addSubview(dot)
        bg.addSubview(titleLabel)
        bg.addSubview(statusLabel)
        bg.addSubview(stopButton)
        contentView = bg
    }

    func setRecording(_ recording: Bool, frameCount: Int, duration: TimeInterval) {
        let seconds = Int(duration.rounded())
        statusLabel.stringValue = String(format: "%02d:%02d · %d 帧", seconds / 60, seconds % 60, frameCount)
        dot.layer?.opacity = recording ? 1 : 0.25
        titleLabel.stringValue = recording ? "录制 GIF" : "准备保存…"
    }

    @objc private func stopTapped() { onStop?() }
}
