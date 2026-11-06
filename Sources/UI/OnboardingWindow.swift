import AppKit

// MARK: - 卡片窗口基础

/// 无边框、圆角卡片风格的浮动窗口（首次引导 / 权限引导共用）。
@MainActor
final class CardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 卡片窗口的根视图：绘制圆角卡片背景，处理 ESC / Return。
@MainActor
final class CardWindowRootView: NSView {
    var cornerRadius: CGFloat = 22
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        PSTheme.cardBackground.setFill()
        path.fill()
        PSTheme.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            onEscape?()
        case 36, 76: // Return / Enter
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - 动态颜色小控件

/// 用 draw 而非 layer 背景色，保证动态颜色随浅色/深色实时解析。
@MainActor
final class DynamicFillView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat { didSet { needsDisplay = true } }

    init(fillColor: NSColor, cornerRadius: CGFloat = 0) {
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else {
            bounds.fill()
        }
    }
}

/// 状态圆点（权限状态）。
@MainActor
final class StatusDotView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// 权限引导里的数字圆圈。
@MainActor
final class NumberBadgeView: NSView {
    private let number: String

    init(number: String) {
        self.number = number
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        PSTheme.accentSoft.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.mono(10.5, weight: .semibold),
            .foregroundColor: PSTheme.accent
        ]
        let size = (number as NSString).size(withAttributes: attributes)
        (number as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - 首次引导

/// 首次启动的引导窗口：品牌、快捷键、自动隐藏、权限状态。
@MainActor
final class OnboardingWindowController: NSWindowController {

    static let shared = OnboardingWindowController()

    private let rootView = CardWindowRootView()
    private let permissionDot = StatusDotView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private var settingsButton: PinButton?
    private var activationObserver: NSObjectProtocol?

    init() {
        let window = CardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        refreshPermission()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 展示

    func present() {
        refreshPermission()
        guard let window else { return }
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(rootView)
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
        }
    }

    func dismiss() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        window?.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let size = window.frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    // MARK: 内容

    private func buildContent() {
        guard let window else { return }
        rootView.frame = NSRect(origin: .zero, size: window.frame.size)
        rootView.onEscape = { [weak self] in self?.dismiss() }
        rootView.onReturn = { [weak self] in self?.startUsing() }
        window.contentView = rootView

        let closeButton = makeCloseButton()
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = PSTheme.label("PinShot", font: PSTheme.display(32, weight: .semibold), color: PSTheme.textPrimary)
        title.alignment = .center
        let subtitle = PSTheme.label("把截图钉在屏幕最上层", font: PSTheme.text(14), color: PSTheme.textSecondary)
        subtitle.alignment = .center

        let features = NSStackView(views: [
            featureRow(leading: PSTheme.makeKeycap("⇧⌘2"), text: "框选区域，松手即贴图"),
            featureRow(leading: PSTheme.makeKeycap("⇧⌘1"), text: "只复制到剪贴板，不贴图"),
            featureRow(
                leading: PSTheme.makeIconBadge(symbol: "eye.slash", tint: PSTheme.accent),
                text: "移开自动淡出，扫回即恢复"
            )
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 10
        features.translatesAutoresizingMaskIntoConstraints = false

        let permissionRow = buildPermissionRow()
        let startButton = PSTheme.makeButton(
            title: "开始使用",
            style: .primary,
            target: self,
            action: #selector(startUsing)
        )
        startButton.contentInset = NSSize(width: 28, height: 13)
        startButton.buttonFont = PSTheme.text(14, weight: .semibold)

        let buttons = NSStackView(views: [startButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 14
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [iconView, title, subtitle, features, permissionRow, buttons])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 0
        content.setCustomSpacing(18, after: iconView)
        content.setCustomSpacing(6, after: title)
        content.setCustomSpacing(26, after: subtitle)
        content.setCustomSpacing(26, after: features)
        content.setCustomSpacing(22, after: permissionRow)
        content.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(content)
        rootView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84),

            content.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 6),
            content.topAnchor.constraint(greaterThanOrEqualTo: rootView.topAnchor, constant: 36),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 44),
            content.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -44),

            features.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            features.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),

            permissionRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            permissionRow.widthAnchor.constraint(equalToConstant: 440),

            closeButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16)
        ])
    }

    private func featureRow(leading: NSView, text: String) -> NSView {
        let label = PSTheme.label(text, font: PSTheme.text(13), color: PSTheme.textPrimary)
        let stack = NSStackView(views: [leading, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func buildPermissionRow() -> NSView {
        let container = DynamicFillView(fillColor: PSTheme.keycapBackground, cornerRadius: 10)

        permissionDot.translatesAutoresizingMaskIntoConstraints = false

        permissionLabel.font = PSTheme.text(12, weight: .medium)
        permissionLabel.textColor = PSTheme.textSecondary
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = PSTheme.makeButton(
            title: "打开设置",
            style: .text,
            target: self,
            action: #selector(openPermissionSettings)
        )
        settingsButton = button

        container.addSubview(permissionDot)
        container.addSubview(permissionLabel)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 42),
            permissionDot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            permissionDot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            permissionDot.widthAnchor.constraint(equalToConstant: 8),
            permissionDot.heightAnchor.constraint(equalToConstant: 8),
            permissionLabel.leadingAnchor.constraint(equalTo: permissionDot.trailingAnchor, constant: 9),
            permissionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: permissionLabel.trailingAnchor, constant: 8)
        ])
        return container
    }

    private func makeCloseButton() -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            button.image = image.withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.contentTintColor = PSTheme.textSecondary
        }
        button.target = self
        button.action = #selector(dismissAction)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }

    // MARK: 状态

    private func refreshPermission() {
        let granted = ScreenCapturer.hasScreenRecordingPermission()
        permissionDot.color = granted ? PSTheme.success : PSTheme.warning
        permissionLabel.stringValue = granted
            ? "屏幕录制权限已就绪"
            : "首次截图需要授权「屏幕录制」"
        permissionLabel.textColor = granted ? PSTheme.textSecondary : PSTheme.textPrimary
        settingsButton?.titleText = granted ? "查看" : "去授权"
        settingsButton?.needsDisplay = true
    }

    // MARK: 动作

    @objc private func startUsing() {
        dismiss()
    }

    @objc private func dismissAction() {
        dismiss()
    }

    @objc private func openSettings() {
        dismiss()
        SettingsWindowController.shared.show(pane: .capture)
    }

    @objc private func openPermissionSettings() {
        if ScreenCapturer.hasScreenRecordingPermission() {
            ScreenCapturer.openScreenRecordingSettings()
        } else {
            ScreenCapturer.requestScreenRecordingPermission()
            ScreenCapturer.openScreenRecordingSettings()
        }
    }
}

// MARK: - 权限引导

/// 屏幕录制权限引导窗口（替代系统 NSAlert）。
///
/// 除「打开系统设置」外提供「重新检查」：用一次真实截图探测权限，
/// 避免 CGPreflight 缓存滞后导致“系统里已勾选但一直提示未授权”。
/// 若授权条目因 ad-hoc 重建失效，可一键 tccutil reset 后退出重开。
@MainActor
final class PermissionGuideWindowController: NSWindowController {

    static let shared = PermissionGuideWindowController()

    private let rootView = CardWindowRootView()
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var primaryButton: PinButton?
    private var recheckButton: PinButton?
    private var laterButton: PinButton?
    private var helpButton: PinButton?

    private var onAuthorized: (() -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var isProbing = false

    init() {
        let window = CardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(onAuthorized: (() -> Void)? = nil) {
        self.onAuthorized = onAuthorized
        refresh()
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(rootView)
        installActivationObserverIfNeeded()
    }

    func dismiss() {
        window?.orderOut(nil)
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        isProbing = false
    }

    // MARK: - 内容

    private func buildContent() {
        guard let window else { return }
        rootView.frame = NSRect(origin: .zero, size: window.frame.size)
        rootView.cornerRadius = 22
        rootView.onEscape = { [weak self] in self?.dismiss() }
        rootView.onReturn = { [weak self] in self?.primaryAction() }
        window.contentView = rootView

        let iconBadge = PSTheme.makeIconBadge(symbol: "rectangle.dashed.badge.record", tint: PSTheme.warning, size: 62)
        let title = PSTheme.label("需要屏幕录制权限", font: PSTheme.display(24, weight: .semibold), color: PSTheme.textPrimary)
        title.alignment = .center
        let subtitle = makeWrappingLabel(
            "PinShot 需要读取屏幕画面才能框选截图。授权后通常需要重启应用；也可以点「重新检查」直接生效。",
            font: PSTheme.text(12),
            color: PSTheme.textSecondary
        )
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 430

        let steps = NSStackView(views: [
            stepRow(index: "1", text: "打开「系统设置 → 隐私与安全性」"),
            stepRow(index: "2", text: "在「屏幕录制」中勾选 PinShot"),
            stepRow(index: "3", text: "回到这里点「重新检查」，或重启 PinShot")
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 9
        steps.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = PSTheme.text(12, weight: .medium)
        statusLabel.textColor = PSTheme.textSecondary
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)

        hintLabel.font = PSTheme.text(11)
        hintLabel.textColor = PSTheme.warning
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.cell?.usesSingleLineMode = false
        hintLabel.cell?.wraps = true
        hintLabel.cell?.isScrollable = false
        hintLabel.preferredMaxLayoutWidth = 440
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let primary = PSTheme.makeButton(
            title: "打开系统设置",
            style: .primary,
            target: self,
            action: #selector(primaryAction)
        )
        primary.contentInset = NSSize(width: 22, height: 12)
        primaryButton = primary

        let recheck = PSTheme.makeButton(
            title: "重新检查",
            style: .secondary,
            target: self,
            action: #selector(recheckAction)
        )
        recheck.contentInset = NSSize(width: 16, height: 12)
        recheckButton = recheck

        let later = PSTheme.makeButton(
            title: "稍后",
            style: .text,
            target: self,
            action: #selector(dismissAction)
        )
        laterButton = later

        let help = PSTheme.makeButton(
            title: "授权无效？查看重新授权步骤",
            style: .text,
            target: self,
            action: #selector(authorizeHelpAction)
        )
        help.buttonFont = PSTheme.text(11, weight: .medium)
        help.isHidden = true
        helpButton = help

        let buttons = NSStackView(views: [primary, recheck, later])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [iconBadge, title, subtitle, steps, statusRow, hintLabel, buttons, help])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 0
        content.setCustomSpacing(16, after: iconBadge)
        content.setCustomSpacing(8, after: title)
        content.setCustomSpacing(18, after: subtitle)
        content.setCustomSpacing(16, after: steps)
        content.setCustomSpacing(12, after: statusRow)
        content.setCustomSpacing(10, after: hintLabel)
        content.setCustomSpacing(16, after: buttons)
        content.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            content.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 32),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -40),

            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            steps.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),

            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func makeWrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = PSTheme.label(text, font: font, color: color)
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func stepRow(index: String, text: String) -> NSView {
        let number = NumberBadgeView(number: index)
        let label = PSTheme.label(text, font: PSTheme.text(13), color: PSTheme.textPrimary)
        let stack = NSStackView(views: [number, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - 状态与授权流程

    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                // 用户从系统设置返回：自动真实探测一次，避免授权已生效却仍显示未授权
                if !ScreenCapturer.hasScreenRecordingPermission(), !self.isProbing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.recheck(showHintOnFailure: false)
                    }
                }
            }
        }
    }

    private func refresh() {
        let granted = ScreenCapturer.hasScreenRecordingPermission()
        statusDot.color = granted ? PSTheme.success : PSTheme.warning
        statusLabel.stringValue = granted
            ? "已获得屏幕录制权限，可以开始截图"
            : "当前状态：未授权"
        primaryButton?.titleText = granted ? "开始使用" : "打开系统设置"
        primaryButton?.needsDisplay = true
        recheckButton?.isHidden = granted
        laterButton?.titleText = granted ? "关闭" : "稍后"
        laterButton?.needsDisplay = true
        helpButton?.isHidden = true
        if granted { hintLabel.isHidden = true }
    }

    private func recheck(showHintOnFailure: Bool = true) {
        guard !isProbing else { return }
        isProbing = true
        recheckButton?.titleText = "检查中…"
        recheckButton?.isEnabled = false

        Task { @MainActor in
            let ok = await ScreenCapturer.probeCapturePermission()
            self.isProbing = false
            self.recheckButton?.titleText = "重新检查"
            self.recheckButton?.isEnabled = true
            if ok {
                self.handleAuthorized()
            } else {
                self.statusDot.color = PSTheme.warning
                self.statusLabel.stringValue = "仍未获得授权"
                if showHintOnFailure {
                    self.hintLabel.stringValue = "若刚在系统设置授权：请退出并重新打开 PinShot 后再试。若重启后仍提示未授权（重新构建后旧授权条目会失效），需要删除旧条目并重新添加 App。"
                    self.hintLabel.isHidden = false
                    self.helpButton?.isHidden = false
                }
            }
        }
    }

    private func handleAuthorized() {
        statusDot.color = PSTheme.success
        statusLabel.stringValue = "已获得屏幕录制权限，正在继续截图…"
        hintLabel.isHidden = true
        helpButton?.isHidden = true
        let action = onAuthorized
        onAuthorized = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.dismiss()
            action?()
        }
    }

    @objc private func primaryAction() {
        if ScreenCapturer.hasScreenRecordingPermission() {
            handleAuthorized()
        } else {
            ScreenCapturer.requestScreenRecordingPermission()
            ScreenCapturer.openScreenRecordingSettings()
            refresh()
        }
    }

    @objc private func recheckAction() {
        recheck()
    }

    /// 说明 macOS 里「开关已开但仍无效」的修复步骤：删除旧条目 → 重新添加当前 App。
    @objc private func authorizeHelpAction() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "重新授权 PinShot"
        alert.informativeText = """
        如果「屏幕录制」里 PinShot 的开关已经是打开状态，但 PinShot 仍提示未授权，通常是重新构建后旧的授权条目失效了。

        修复步骤：
        1. 打开「系统设置 → 隐私与安全性 → 屏幕录制」
        2. 选中列表里所有名为 PinShot 的条目，逐一点「−」删除（旧构建可能留下多条）
           macOS 会要求 Touch ID 或输入密码验证，请先通过验证
        3. 点「＋」，选择下面这个 App（或点「在 Finder 中显示」后把它拖进列表）：
           \(Bundle.main.bundlePath)
        4. 打开 PinShot 开关；如果系统提示，选择「退出并重新打开」
        5. 回到 PinShot，点「重新检查」

        只需做一次。本版本已使用跨构建稳定的签名 requirement，之后重新构建不会再让授权失效。

        暂时不想处理授权？可以先用系统截图 ⇧⌃⌘4 把图片复制到剪贴板，再从菜单栏选择「从剪贴板贴图…」，同样可以标注和贴图。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            ScreenCapturer.requestScreenRecordingPermission()
            ScreenCapturer.openScreenRecordingSettings()
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    @objc private func dismissAction() {
        dismiss()
    }
}
