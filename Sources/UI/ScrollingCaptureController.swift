import AppKit
import ApplicationServices
import CoreGraphics

/// 滚动截图控制器（Shottr 风格）：
///
/// 1. 用选区冻结帧做起始帧（`CaptureGeometry.pinImage`）；
/// 2. 自动模式：把光标移到选区中心，用 CGEvent 逐格滚动（pixel 单位，约 200–400px / 200–300ms），
///    每帧用 `ScreenCapturer().captureAllScreens()` 重抓同屏区域并裁剪，增量交给 `ScrollingStitcher` 拼接；
/// 3. 无「辅助功能」权限或合成滚动不生效时，自动退化为手动滚动模式：HUD 提示用户自行滚动页面，定时抓帧；
/// 4. HUD 是选区外的深色 NSPanel：显示帧数 / 像素高度，Esc 取消、Enter 提前完成（手动模式可点击 HUD 完成）；
/// 5. 完成 / 取消回调恰好一次；拼接高度上限 200,000px，最多约 20 帧，到页尾 / 异常自动收尾，不会卡死。
@MainActor
final class ScrollingCaptureController {

    // MARK: - 对外 API

    enum Mode {
        case pin
        case clipboard
    }

    /// - Parameters:
    ///   - snapshot: 选区出现前的整屏冻结帧
    ///   - selection: 屏幕局部 Cocoa 坐标（左下原点，pt）
    ///   - mode: 完成后的用途（仅影响 HUD 提示；贴图 / 复制由 Coordinator 处理）
    ///   - onComplete: 拼接结果 + 全局 Cocoa 矩形（尺寸已按拼接结果更新，origin 为选区左下角）
    ///   - onCancel: 用户取消 / 无法完成时调用
    init(
        snapshot: ScreenSnapshot,
        selection: CGRect,
        mode: Mode,
        onComplete: @escaping (PinnedImage, CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.mode = mode
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// 开始滚动截图。重复调用无副作用。
    func start() {
        guard !started, !finished else { return }
        started = true

        guard let initialImage = CaptureGeometry.pinImage(from: snapshot, selection: selection, minPixelSize: 2) else {
            NSLog("[PinShot] 滚动截图：选区过小，直接取消")
            finish(.cancelled)
            return
        }
        guard stitcher.begin(with: initialImage.cgImage) else {
            NSLog("[PinShot] 滚动截图：初始帧无法解码，直接取消")
            finish(.cancelled)
            return
        }

        initialCursorLocation = NSEvent.mouseLocation
        presentHUD()

        let accessibilityTrusted = AXIsProcessTrusted()
        installKeyMonitors(allowGlobalMonitor: accessibilityTrusted)

        if accessibilityTrusted {
            loopTask = Task { @MainActor [weak self] in
                await self?.runAutomaticLoop()
            }
        } else {
            NSLog("[PinShot] 滚动截图：没有辅助功能权限，退化为手动滚动")
            beginManualMode(reason: "没有辅助功能权限，请手动滚动页面")
        }
    }

    /// 取消滚动截图；只会触发一次 `onCancel`。
    func cancel() {
        finish(.cancelled)
    }

    // MARK: - 常量

    private enum Timing {
        /// 滚动事件发出后、抓帧前等待画面稳定的时间
        static let autoScrollSettleDelay: UInt64 = 170_000_000
        /// 相邻两次滚动的目标间隔下限（滚动 + 抓帧 + 拼接整体）
        static let autoScrollMinimumCycle: TimeInterval = 0.24
        /// 开始自动滚动前的等待：让选区覆盖层彻底消失、HUD 完成首帧绘制
        static let initialSettleDelay: UInt64 = 250_000_000
        /// 方向校准每一步的等待时间
        static let calibrationSettleDelay: UInt64 = 220_000_000
        /// 手动模式下抓帧间隔
        static let manualCaptureInterval: UInt64 = 400_000_000
        /// 最多帧数（含初始帧）
        static let maximumFrames = 20
        /// 拼接高度硬上限（像素）
        static let maximumPixelHeight = 200_000
        /// 连续多少帧没有新内容后认为已到页尾
        static let maximumIdleFrames = 2
        /// 手动模式安全上限，避免无限挂着
        static let maximumManualDuration: TimeInterval = 300
        /// HUD 与选区的间距
        static let hudGap: CGFloat = 12
        /// 初始滚动步长（事件 pixel 单位）
        static let initialScrollUnits: Double = 300
    }

    // MARK: - 依赖

    private let snapshot: ScreenSnapshot
    private let selection: CGRect
    private let mode: Mode
    private let onComplete: (PinnedImage, CGRect) -> Void
    private let onCancel: () -> Void

    private let stitcher = ScrollingStitcher(
        options: {
            var options = ScrollingStitcher.Options()
            options.maximumHeight = Timing.maximumPixelHeight
            return options
        }()
    )

    // MARK: - 状态

    private var started = false
    private var finished = false
    private var isManualMode = false
    private var manualStartedAt: Date?
    private var initialCursorLocation: CGPoint?
    /// 是否真的挪动过光标（只有自动模式会挪；手动模式不能把用户的光标抢回来）
    private var cursorWarped = false

    private var loopTask: Task<Void, Never>?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var hudPanel: ScrollingHUDPanel?
    private var hudView: ScrollingHUDView?

    // MARK: - 几何 / 文案

    /// 选区在全局 Cocoa 坐标中的矩形
    private var selectionGlobalRect: CGRect {
        CaptureGeometry.globalRect(forSelection: selection, in: snapshot)
    }

    private var outputScale: CGFloat {
        snapshot.scale > 0 ? snapshot.scale : 1
    }

    private var completionHint: String {
        switch mode {
        case .pin:
            return "ENTER 完成"
        case .clipboard:
            return "ENTER 完成（复制）"
        }
    }

    private func frameStatus() -> String {
        "\(stitcher.frameCount) 帧 · \(Self.formattedNumber(stitcher.totalHeight)) px"
    }

    // MARK: - HUD

    private func presentHUD() {
        let size = CGSize(width: 420, height: 76)
        let panel = ScrollingHUDPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false

        let view = ScrollingHUDView(frame: CGRect(origin: .zero, size: size))
        view.onClick = { [weak self] in
            guard let self else { return }
            self.finishCompleted(reason: "用户点击 HUD 完成")
        }
        panel.contentView = view
        panel.setFrame(hudFrame(for: size), display: false)
        panel.orderFrontRegardless()

        hudPanel = panel
        hudView = view
        updateHUD(title: "滚动截图中…", status: frameStatus(), hint: "ESC 取消 · \(completionHint)")
    }

    private func updateHUD(title: String, status: String, hint: String) {
        hudView?.title = title
        hudView?.status = status
        hudView?.hint = hint
    }

    /// 把 HUD 放到选区外：优先右侧 / 左侧 / 上方 / 下方，都放不下时取与选区重叠面积最小的位置。
    private func hudFrame(for size: CGSize) -> CGRect {
        let selectionRect = selectionGlobalRect
        let screen = NSScreen.screens.first(where: { ScreenCapturer.displayID(of: $0) == snapshot.displayID })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(selectionRect) })
            ?? NSScreen.main

        guard let screen else {
            return CGRect(
                x: selectionRect.minX,
                y: selectionRect.minY - size.height - Timing.hudGap,
                width: size.width,
                height: size.height
            )
        }

        let visible = screen.visibleFrame
        let gap = Timing.hudGap
        let candidates: [CGRect] = [
            CGRect(x: selectionRect.maxX + gap, y: selectionRect.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: selectionRect.minX - gap - size.width, y: selectionRect.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: selectionRect.midX - size.width / 2, y: selectionRect.maxY + gap, width: size.width, height: size.height),
            CGRect(x: selectionRect.midX - size.width / 2, y: selectionRect.minY - gap - size.height, width: size.width, height: size.height)
        ]

        var bestFrame: CGRect?
        var bestOverlapArea: CGFloat = .greatestFiniteMagnitude
        for candidate in candidates {
            let clamped = Self.clamped(candidate, into: visible)
            let intersection = clamped.intersection(selectionRect)
            let overlapArea = intersection.isNull ? 0 : intersection.width * intersection.height
            if overlapArea <= 0 {
                return clamped
            }
            if overlapArea < bestOverlapArea {
                bestOverlapArea = overlapArea
                bestFrame = clamped
            }
        }
        if bestFrame != nil {
            NSLog("[PinShot] 滚动截图：选区几乎铺满屏幕，HUD 已尽量贴边")
        }
        return bestFrame ?? candidates[0]
    }

    // MARK: - 自动滚动

    private func runAutomaticLoop() async {
        isManualMode = false
        hudPanel?.ignoresMouseEvents = true
        updateHUD(title: "滚动截图中…", status: frameStatus(), hint: "ESC 取消 · \(completionHint)")
        try? await Task.sleep(nanoseconds: Timing.initialSettleDelay)
        guard !finished else { return }
        warpCursorToSelectionCenter()

        // 先校准滚动方向（同时吃掉第一帧）。失败说明合成滚动不可用，退化手动模式。
        guard let scrollSign = await calibrateScrollDirection() else {
            guard !finished else { return }
            beginManualMode(reason: "合成滚动没有产生画面变化，请手动滚动页面")
            return
        }
        guard !finished else { return }

        var scrollUnits = Timing.initialScrollUnits
        var consecutiveIdle = 0
        var consecutiveAnomaly = 0
        var consecutiveInvalid = 0

        while !finished {
            guard !Task.isCancelled else { return }
            if stitcher.frameCount >= Timing.maximumFrames {
                finishCompleted(reason: "已达到最大帧数 \(Timing.maximumFrames)")
                return
            }

            let cycleStart = Date()
            postScroll(delta: Double(scrollSign) * scrollUnits)
            try? await Task.sleep(nanoseconds: Timing.autoScrollSettleDelay)
            guard !finished else { return }

            guard let image = await captureSelectionFrame() else {
                if finished { return }
                consecutiveInvalid += 1
                if consecutiveInvalid >= 3 {
                    finishCompleted(reason: "连续抓帧失败，按当前内容完成")
                    return
                }
                continue
            }
            guard !finished else { return }
            consecutiveInvalid = 0

            let frameHeight = image.height
            let result = stitcher.append(image)
            switch result.outcome {
            case .appended, .appendedWeak:
                consecutiveIdle = 0
                consecutiveAnomaly = 0
                adaptScrollUnits(&scrollUnits, overlap: result.overlapRows, frameHeight: frameHeight)
                updateHUD(title: "滚动截图中…", status: frameStatus(), hint: "ESC 取消 · \(completionHint)")
            case .appendedWholeFrame:
                // 重叠异常：缩小步长继续尝试，连续两帧仍异常就收尾
                consecutiveIdle = 0
                consecutiveAnomaly += 1
                scrollUnits = max(80, scrollUnits * 0.6)
                updateHUD(title: "滚动截图中…", status: frameStatus(), hint: "ESC 取消 · \(completionHint)")
            case .identical:
                consecutiveIdle += 1
                if consecutiveIdle >= Timing.maximumIdleFrames {
                    finishCompleted(reason: "画面不再滚动，已到页面底部")
                    return
                }
            case .reversed:
                finishCompleted(reason: "检测到画面反向滚动，停止自动滚动")
                return
            case .widthMismatch, .invalidImage:
                consecutiveInvalid += 1
                if consecutiveInvalid >= 3 {
                    finishCompleted(reason: "抓帧尺寸异常，按当前内容完成")
                    return
                }
            case .heightLimit:
                finishCompleted(reason: "已达到高度上限 \(Self.formattedNumber(Timing.maximumPixelHeight))px")
                return
            }

            if result.reachedHeightLimit {
                finishCompleted(reason: "已达到高度上限 \(Self.formattedNumber(Timing.maximumPixelHeight))px")
                return
            }
            if result.outcome == .appendedWholeFrame, consecutiveAnomaly >= 2 {
                finishCompleted(reason: "连续多帧无法匹配重叠，停止自动滚动")
                return
            }

            let elapsed = Date().timeIntervalSince(cycleStart)
            if elapsed < Timing.autoScrollMinimumCycle {
                try? await Task.sleep(nanoseconds: UInt64((Timing.autoScrollMinimumCycle - elapsed) * 1_000_000_000))
            }
        }
    }

    /// 用一次真实滚动校准方向：先试「负方向（内容向下滚）」，反向/无效时回滚再试正方向。
    /// 成功时返回应使用的滚动符号，并把已经抓到的这一帧拼进去。
    private func calibrateScrollDirection() async -> Int32? {
        for sign in [Int32(-1), Int32(1)] {
            guard !finished, !Task.isCancelled else { return nil }
            postScroll(delta: Double(sign) * Timing.initialScrollUnits)
            try? await Task.sleep(nanoseconds: Timing.calibrationSettleDelay)
            guard !finished, !Task.isCancelled else { return nil }

            if !finished,
               let image = await captureSelectionFrame(),
               !finished,
               let preview = stitcher.preview(image),
               !preview.widthMismatch {
                if preview.forwardOverlapRows > 0, !preview.isIdentical {
                    let result = stitcher.append(image)
                    NSLog("[PinShot] 滚动截图：方向校准成功 sign=\(sign)，重叠 \(result.overlapRows)px")
                    updateHUD(title: "滚动截图中…", status: frameStatus(), hint: "ESC 取消 · \(completionHint)")
                    return sign
                }
            }

            // 这一步没有产生向下的新内容：回滚，再试另一个方向
            postScroll(delta: Double(-sign) * Timing.initialScrollUnits)
            try? await Task.sleep(nanoseconds: Timing.calibrationSettleDelay)
        }
        return nil
    }

    /// 根据实际观察到的内容位移调整下一次滚动的事件步长，保持约 30% 帧高的新内容。
    private func adaptScrollUnits(_ units: inout Double, overlap: Int, frameHeight: Int) {
        guard frameHeight > 0, overlap > 0 else { return }
        let observedShift = Double(max(1, frameHeight - overlap))
        var desiredShift = min(max(Double(frameHeight) * 0.34, 200), 400)
        desiredShift = min(desiredShift, Double(frameHeight) * 0.55)
        desiredShift = max(desiredShift, 24)

        let unitsPerPixel = units / observedShift
        var target = desiredShift * unitsPerPixel
        // 单次调整限制在 ±35%，避免画面动画 / 惯性导致步长震荡
        target = min(max(target, units * 0.65), units * 1.35)
        units = min(max(target, 24), 2400)
    }

    private func postScroll(delta: Double) {
        let units = Int32(delta.rounded())
        guard units != 0 else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: units,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = Self.cgPoint(fromCocoa: CGPoint(x: selectionGlobalRect.midX, y: selectionGlobalRect.midY))
        event.post(tap: .cghidEventTap)
    }

    private func warpCursorToSelectionCenter() {
        let center = CGPoint(x: selectionGlobalRect.midX, y: selectionGlobalRect.midY)
        cursorWarped = true
        CGWarpMouseCursorPosition(Self.cgPoint(fromCocoa: center))
    }

    private func restoreCursor() {
        guard cursorWarped, let location = initialCursorLocation else { return }
        cursorWarped = false
        initialCursorLocation = nil
        CGWarpMouseCursorPosition(Self.cgPoint(fromCocoa: location))
    }

    // MARK: - 手动滚动（兜底）

    private func beginManualMode(reason: String) {
        guard !finished else { return }
        isManualMode = true
        manualStartedAt = Date()
        loopTask?.cancel()
        loopTask = nil

        NSLog("[PinShot] 滚动截图进入手动模式：\(reason)")
        updateHUD(title: "手动滚动页面", status: frameStatus(), hint: "ESC 取消 · \(completionHint) · 点击此处完成")

        // 手动模式需要键盘焦点：HUD 变成 key，App 激活以拿到本地按键监听。
        // HUD 之外的区域仍然可以正常滚动目标窗口。
        NSApp.activate(ignoringOtherApps: true)
        hudPanel?.ignoresMouseEvents = false
        hudPanel?.makeKeyAndOrderFront(nil)

        loopTask = Task { @MainActor [weak self] in
            await self?.runManualLoop()
        }
    }

    private func runManualLoop() async {
        var consecutiveInvalid = 0

        while !finished {
            guard !Task.isCancelled else { return }
            if let startedAt = manualStartedAt,
               Date().timeIntervalSince(startedAt) > Timing.maximumManualDuration {
                finishCompleted(reason: "手动滚动超时，按当前内容完成")
                return
            }
            if stitcher.frameCount >= Timing.maximumFrames {
                finishCompleted(reason: "已达到最大帧数 \(Timing.maximumFrames)")
                return
            }

            try? await Task.sleep(nanoseconds: Timing.manualCaptureInterval)
            guard !finished else { return }

            guard let image = await captureSelectionFrame() else {
                if finished { return }
                consecutiveInvalid += 1
                if consecutiveInvalid >= 5 {
                    finishCompleted(reason: "连续抓帧失败，按当前内容完成")
                    return
                }
                continue
            }
            guard !finished else { return }
            consecutiveInvalid = 0

            let result = stitcher.append(image)
            switch result.outcome {
            case .appended, .appendedWeak, .appendedWholeFrame:
                break
            case .identical, .reversed:
                // 用户可能停在原地或往回滚：跳过这一帧，继续等待
                break
            case .widthMismatch, .invalidImage:
                consecutiveInvalid += 1
            case .heightLimit:
                finishCompleted(reason: "已达到高度上限 \(Self.formattedNumber(Timing.maximumPixelHeight))px")
                return
            }

            if consecutiveInvalid >= 5 {
                finishCompleted(reason: "连续抓帧异常，按当前内容完成")
                return
            }

            updateHUD(title: "手动滚动页面", status: frameStatus(), hint: "ESC 取消 · \(completionHint) · 点击此处完成")

            if result.reachedHeightLimit {
                finishCompleted(reason: "已达到高度上限 \(Self.formattedNumber(Timing.maximumPixelHeight))px")
                return
            }
        }
    }

    // MARK: - 抓帧

    /// 重抓同屏画面，并按原始选区裁剪成与初始帧同尺寸的帧。
    private func captureSelectionFrame() async -> CGImage? {
        guard !finished else { return nil }
        let result = await ScreenCapturer().captureAllScreens()
        guard case .success(let snapshots) = result else { return nil }

        let target = snapshots.first(where: { $0.displayID == snapshot.displayID })
            ?? snapshots.first(where: { $0.frame.equalTo(snapshot.frame) })
            ?? snapshots.first
        guard let target else { return nil }
        guard let image = CaptureGeometry.pinImage(from: target, selection: selection, minPixelSize: 2) else {
            return nil
        }
        return image.cgImage
    }

    // MARK: - 键盘

    private func installKeyMonitors(allowGlobalMonitor: Bool) {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                consumed = self.handleKeyDown(event)
            }
            return consumed ? nil : event
        }

        // 自动模式下 App 不在前台，需要全局监听才能拿到 Esc / Enter。
        // 全局键盘监听依赖辅助功能权限；没有权限时靠手动模式激活 App + 本地监听兜底。
        guard allowGlobalMonitor else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                _ = self?.handleKeyDown(event)
            }
        }
    }

    private func removeKeyMonitors() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        switch event.keyCode {
        case 53: // Escape
            NSLog("[PinShot] 滚动截图：用户按 Esc 取消")
            finish(.cancelled)
            return true
        case 36, 76: // Return / 小键盘 Enter
            finishCompleted(reason: "用户按 Enter 提前完成")
            return true
        default:
            return false
        }
    }

    // MARK: - 收尾（保证恰好一次回调）

    private enum FinishReason {
        case completed
        case cancelled
    }

    private func finishCompleted(reason: String) {
        guard !finished else { return }
        NSLog("[PinShot] 滚动截图完成（\(isManualMode ? "手动" : "自动")）：\(reason)，帧数=\(stitcher.frameCount)，高度=\(stitcher.totalHeight)px")
        for warning in stitcher.warnings {
            NSLog("[PinShot] 滚动拼接警告：\(warning)")
        }
        finish(.completed)
    }

    private func finish(_ kind: FinishReason) {
        guard !finished else { return }
        finished = true

        loopTask?.cancel()
        loopTask = nil
        removeKeyMonitors()

        hudPanel?.orderOut(nil)
        hudPanel?.close()
        hudPanel = nil
        hudView = nil

        restoreCursor()

        switch kind {
        case .completed:
            guard let image = stitcher.makeImage() else {
                NSLog("[PinShot] 滚动截图：拼接结果为空，按取消处理")
                onCancel()
                return
            }
            let pointSize = CGSize(
                width: max(1, CGFloat(image.width) / outputScale),
                height: max(1, CGFloat(image.height) / outputScale)
            )
            let pinnedImage = PinnedImage(cgImage: image, pointSize: pointSize)
            let globalSelection = selectionGlobalRect
            let placement = CGRect(
                x: globalSelection.minX,
                y: globalSelection.minY,
                width: pointSize.width,
                height: pointSize.height
            )
            NSLog("[PinShot] 滚动截图回调完成：\(image.width)×\(image.height)px，placement=\(placement)")
            onComplete(pinnedImage, placement)
        case .cancelled:
            NSLog("[PinShot] 滚动截图取消")
            onCancel()
        }
    }

    // MARK: - 工具

    /// Cocoa 全局坐标（左下原点）→ CG 全局坐标（主屏左上原点）
    private static func cgPoint(fromCocoa point: CGPoint) -> CGPoint {
        guard let main = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: main.frame.maxY - point.y)
    }

    private static func clamped(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        let minX = bounds.minX + 4
        let maxX = max(minX, bounds.maxX - rect.width - 4)
        let minY = bounds.minY + 4
        let maxY = max(minY, bounds.maxY - rect.height - 4)
        result.origin.x = min(max(rect.origin.x, minX), maxX)
        result.origin.y = min(max(rect.origin.y, minY), maxY)
        return result
    }

    private static func formattedNumber(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3, value >= 0 else { return digits }
        var reversed = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 {
                reversed.append(",")
            }
            reversed.append(character)
        }
        return String(reversed.reversed())
    }
}

// MARK: - HUD 面板

/// 无边框、非激活式 HUD 面板：不抢目标 App 的焦点（手动模式下可临时成为 key 以接收键盘）。
private final class ScrollingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 深色圆角 HUD：上行「状态 + 帧数 / 高度」，下行「快捷键提示」。
private final class ScrollingHUDView: NSView {

    var title: String = "" {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    var status: String = "" {
        didSet { if status != oldValue { needsDisplay = true } }
    }
    var hint: String = "" {
        didSet { if hint != oldValue { needsDisplay = true } }
    }
    /// 手动模式下点击 HUD 完成（自动模式下 HUD 不接收鼠标事件）
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let cornerRadius: CGFloat = 16

        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor.black.withAlphaComponent(0.84).setFill()
        card.fill()
        card.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        card.stroke()

        let horizontalInset: CGFloat = 16

        // 状态圆点（信号橙，呼应 App 设计系统）
        let dotDiameter: CGFloat = 6
        let dot = CGRect(x: horizontalInset, y: 17, width: dotDiameter, height: dotDiameter)
        PSTheme.accent.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.text(13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        (title as NSString).draw(
            at: CGPoint(x: horizontalInset + dotDiameter + 8, y: 11),
            withAttributes: titleAttributes
        )

        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.mono(12, weight: .medium),
            .foregroundColor: PSTheme.accent
        ]
        let statusSize = (status as NSString).size(withAttributes: statusAttributes)
        (status as NSString).draw(
            at: CGPoint(x: bounds.maxX - horizontalInset - statusSize.width, y: 11.5),
            withAttributes: statusAttributes
        )

        // 分隔线
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(
            rect: CGRect(
                x: horizontalInset,
                y: 40,
                width: bounds.width - horizontalInset * 2,
                height: 1
            )
        ).fill()

        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.mono(11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.52)
        ]
        (hint as NSString).draw(
            at: CGPoint(x: horizontalInset, y: 49),
            withAttributes: hintAttributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
