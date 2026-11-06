import AppKit

/// 全局自动隐藏管理器。
///
/// 所有挂件共享同一个 0.2s 定时器，轮询 `NSEvent.mouseLocation`（全局鼠标位置，
/// 无需辅助功能 / 输入监控权限），按每个挂件窗口的 frame 判定悬停，然后驱动
/// `PinWindowController.setAutoHidden(_:animated:)`。
///
/// 状态机（每个挂件独立计时）：
/// - 挂在桌面的贴图（`pinPlacement == .desktop`）跳过自动隐藏，始终正常可见；
/// - 自动隐藏关闭 / 暂停 / 被「隐藏全部」强制隐藏 → 强制显示；
/// - 鼠标在窗口内（外扩 2pt）→ 立即恢复；重置离开计时；
/// - 鼠标在外 → 记录离开时刻，超过 `settings.autoHideDelay` 后进入自动隐藏；
/// - 拖拽 / 缩放期间不打断（由 `PinWindowController.isInteracting` 判断）。
@MainActor
final class AutoHideManager {
    static let shared = AutoHideManager()

    /// 一个被跟踪的挂件。`leaveStartedAt` 为 nil 表示当前没有在计时。
    private struct TrackedPin {
        let pin: PinWindowController
        var leaveStartedAt: Date?
    }

    private var tracked: [TrackedPin] = []
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .pinShotSettingsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 注册 / 注销

    /// 注册一个挂件。`renderOnly` 的离线自检挂件不参与自动隐藏。
    func register(_ pin: PinWindowController) {
        guard !pin.renderOnly else { return }
        guard !tracked.contains(where: { $0.pin === pin }) else { return }
        // 初始不启动离开计时：等第一次轮询发现鼠标在外时再开始，
        // 这样新建挂件至少会完整显示一个「离开延迟」，不会刚出现就淡出。
        tracked.append(TrackedPin(pin: pin, leaveStartedAt: nil))
        startTimerIfNeeded()
        poll(now: Date())
    }

    func unregister(_ pin: PinWindowController) {
        tracked.removeAll { $0.pin === pin }
        if tracked.isEmpty {
            stopTimer()
        }
    }

    /// 设置变化后立即重新计算一遍（不再等下一次定时器）。
    func refreshAll() {
        poll(now: Date())
    }

    // MARK: - 轮询

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: PinShotConstants.autoHidePollInterval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.02
        // .common 模式：菜单跟踪、拖拽等 runloop 模式下也继续轮询
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired() {
        poll(now: Date())
    }

    private func poll(now: Date) {
        guard !tracked.isEmpty else {
            stopTimer()
            return
        }

        let settings = AppSettings.shared
        let mouseLocation = NSEvent.mouseLocation

        for index in tracked.indices {
            let pin = tracked[index].pin

            // 窗口不可见（强制隐藏 / 截图前临时隐藏 / 已关闭）或强制隐藏时不参与自动隐藏
            guard let window = pin.window, window.isVisible, !pin.isForcedHidden else {
                tracked[index].leaveStartedAt = nil
                continue
            }

            // 挂在桌面的贴图不参与自动隐藏：保持正常不透明度、不可点击穿透
            if pin.pinPlacement == .desktop {
                tracked[index].leaveStartedAt = nil
                pin.setAutoHidden(false, animated: true)
                continue
            }

            // 拖拽 / 缩放中：保持显示，不开始计时
            if pin.isInteracting {
                tracked[index].leaveStartedAt = nil
                pin.setAutoHidden(false, animated: true)
                continue
            }

            // 自动隐藏被关闭 / 暂停：强制恢复正常显示
            if !settings.autoHideEnabled || settings.autoHidePaused {
                tracked[index].leaveStartedAt = nil
                pin.setAutoHidden(false, animated: true)
                continue
            }

            // 悬停判定：窗口 frame 外扩 2pt，避免贴边时闪动
            let hoverFrame = window.frame.insetBy(dx: -2, dy: -2)
            if hoverFrame.contains(mouseLocation) {
                tracked[index].leaveStartedAt = nil
                pin.setAutoHidden(false, animated: true)
            } else {
                if tracked[index].leaveStartedAt == nil {
                    tracked[index].leaveStartedAt = now
                }
                if let leaveStartedAt = tracked[index].leaveStartedAt,
                   now.timeIntervalSince(leaveStartedAt) >= settings.autoHideDelay {
                    pin.setAutoHidden(true, animated: true)
                }
            }
        }
    }

    // MARK: - 设置变化

    @objc private func settingsDidChange(_ notification: Notification) {
        refreshAll()
    }
}
