import AppKit

/// 轻量 HUD 提示（不抢焦点、不进入窗口列表），用于「贴图挂在桌面」这种容易被误认为丢失的状态。
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(_ message: String, duration: TimeInterval = 2.6) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let font = PSTheme.text(12.5, weight: .medium)
        let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
        let size = NSSize(width: min(520, textWidth + 40), height: 40)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 0.94).cgColor
        background.layer?.cornerRadius = 10
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.90, alpha: 1)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: 9, width: size.width - 32, height: 22)
        background.addSubview(label)

        panel.contentView = background
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self.panel === panel { self.panel = nil }
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
