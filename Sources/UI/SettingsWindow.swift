import AppKit

// MARK: - 设置窗口

/// PinShot 设置窗口（UI 改版：侧边栏 + 内容面板）。
///
/// 左侧 220pt 侧边栏（App 标识、4 个导航、权限状态与版本），
/// 右侧内容页（大标题 + 说明 + 圆角卡片）。视觉全部来自 `PSTheme` 与 `Controls.swift`。
/// 所有控件变化立即写回 `AppSettings.shared`；`show()` 与设置变更通知都会刷新控件状态。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// 设置窗口的 4 个导航页
    enum Pane: Int, CaseIterable {
        case capture
        case pin
        case launch
        case about
    }

    static let shared = SettingsWindowController()

    private let settings = AppSettings.shared
    /// 正在把 UI 值写回 settings，此时忽略 settingsDidChange，避免拖动滑杆时抖动
    private var isApplyingUserChange = false
    private var selectedPane: Pane = .capture

    // MARK: 骨架
    private let rootView = SettingsRootView(frame: .zero)
    private let sidebarView = NSView()
    private let contentHost = NSView()
    private var paneViews: [Pane: NSView] = [:]
    private var paneScrollViews: [Pane: NSScrollView] = [:]
    private var navButtons: [Pane: SidebarNavButton] = [:]

    // MARK: 截图页
    private var pinHotKeyRow: HotKeyRowView!
    private var copyHotKeyRow: HotKeyRowView!

    // MARK: 贴图页
    private let autoHideSwitch = PinSwitch()
    private let hideEntirelySwitch = PinSwitch()
    private let clickThroughSwitch = PinSwitch()
    private let borderSwitch = PinSwitch()
    private let shadowSwitch = PinSwitch()
    private let desktopPlacementSwitch = PinSwitch()
    private let delaySlider = PinSlider()
    private let ghostSlider = PinSlider()
    private let delayValueLabel = PSTheme.label("", font: PSTheme.mono(11), color: PSTheme.textPrimary, alignment: .right)
    private let ghostValueLabel = PSTheme.label("", font: PSTheme.mono(11), color: PSTheme.textPrimary, alignment: .right)

    // MARK: 启动与权限页
    private let launchAtLoginSwitch = PinSwitch()
    private var launchPermissionRow: SettingsRowView!
    private let launchPermissionDot = PermissionDotView()
    private let openSettingsPrimaryButton = PinButton(title: "打开系统设置", style: .primary)
    private let openSettingsSecondaryButton = PinButton(title: "打开系统设置", style: .secondary)
    private let recheckPermissionButton = PinButton(title: "重新检查", style: .text)
    private let resetDefaultsButton = PinButton(title: "恢复默认…", style: .text)

    // MARK: 关于页 / 侧边栏
    private let aboutPinKeycap = KeycapSlotView(frame: .zero)
    private let aboutCopyKeycap = KeycapSlotView(frame: .zero)
    private let sidebarStatus = SidebarStatusView()

    // MARK: 生命周期

    private init() {
        let size = PSTheme.settingsWindowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PinShot 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = PSTheme.sidebarBackground
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)

        window.delegate = self
        configureControls()
        buildRootView()
        buildSidebar()
        buildPaneViews()
        refreshFromSettings()
        selectPane(.capture)

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

    // MARK: - 对外接口

    /// 打开设置窗口；`pane` 指定初始导航页（默认「截图」）。
    func show(pane: Pane = .capture) {
        refreshFromSettings()
        selectPane(pane)
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// `--render-ui` 离屏渲染准备：切换外观、布置到屏幕外并完成一次布局。
    func debugPrepareForRendering(appearance: NSAppearance) {
        window?.appearance = appearance
        rootView.appearance = appearance
        if let window {
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
        }
        refreshFromSettings()
        markNeedsDisplay(rootView)
        rootView.layoutSubtreeIfNeeded()
    }

    /// `--render-ui` 切换导航页（不播动画、不激活 App）。
    func debugSelectPane(_ pane: Pane) {
        selectPane(pane)
        markNeedsDisplay(rootView)
        rootView.layoutSubtreeIfNeeded()
    }

    /// 供 `--render-ui` 截图的内容视图（820×600）。
    var renderContentView: NSView? { rootView }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cancelAllRecordings()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelAllRecordings()
    }

    // MARK: - 控件配置

    private func configureControls() {
        configureSwitch(autoHideSwitch, label: "自动隐藏贴图", action: #selector(autoHideToggled(_:)))
        configureSwitch(hideEntirelySwitch, label: "完全隐藏", action: #selector(hideEntirelyToggled(_:)))
        configureSwitch(clickThroughSwitch, label: "隐藏时点击穿透", action: #selector(clickThroughToggled(_:)))
        configureSwitch(borderSwitch, label: "贴图边框", action: #selector(borderToggled(_:)))
        configureSwitch(shadowSwitch, label: "贴图阴影", action: #selector(shadowToggled(_:)))
        configureSwitch(desktopPlacementSwitch, label: "新贴图挂在桌面", action: #selector(desktopPlacementToggled(_:)))
        configureSwitch(launchAtLoginSwitch, label: "登录时自动启动", action: #selector(launchAtLoginToggled(_:)))

        delaySlider.minValue = 0.5
        delaySlider.maxValue = 10
        delaySlider.target = self
        delaySlider.action = #selector(delaySliderChanged(_:))
        delaySlider.setAccessibilityLabel("隐藏延迟")

        ghostSlider.minValue = 0.05
        ghostSlider.maxValue = 0.6
        ghostSlider.target = self
        ghostSlider.action = #selector(ghostSliderChanged(_:))
        ghostSlider.setAccessibilityLabel("幽灵透明度")

        for label in [delayValueLabel, ghostValueLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        }

        openSettingsPrimaryButton.target = self
        openSettingsPrimaryButton.action = #selector(openScreenRecordingSettings(_:))
        openSettingsPrimaryButton.setAccessibilityLabel("打开系统设置的屏幕录制权限")
        openSettingsSecondaryButton.target = self
        openSettingsSecondaryButton.action = #selector(openScreenRecordingSettings(_:))
        recheckPermissionButton.target = self
        recheckPermissionButton.action = #selector(recheckPermission(_:))
        resetDefaultsButton.target = self
        resetDefaultsButton.action = #selector(resetDefaults(_:))
    }

    private func configureSwitch(_ toggle: PinSwitch, label: String, action: Selector) {
        toggle.target = self
        toggle.action = action
        toggle.setLabel(label)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - 骨架布局

    private func buildRootView() {
        guard let contentView = window?.contentView else { return }

        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.frame = contentView.bounds
        rootView.autoresizingMask = [.width, .height]
        contentView.addSubview(rootView)
        // 固定尺寸窗口：显式锁死尺寸，避免 Auto Layout 反推窗口内容尺寸
        rootView.widthAnchor.constraint(equalToConstant: PSTheme.settingsWindowSize.width).isActive = true
        rootView.heightAnchor.constraint(equalToConstant: PSTheme.settingsWindowSize.height).isActive = true

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(sidebarView)
        rootView.addSubview(contentHost)
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: PSTheme.sidebarWidth),

            contentHost.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func buildSidebar() {
        let appIcon = AppIconWellView(size: 56)
        let nameLabel = PSTheme.label("PinShot", font: PSTheme.display(18, weight: .semibold), color: PSTheme.textPrimary)
        let taglineLabel = PSTheme.label("截图挂件", font: PSTheme.text(11), color: PSTheme.textSecondary)

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for pane in Pane.allCases {
            let button = SidebarNavButton(pane: pane, title: Self.navTitle(for: pane), symbol: Self.navSymbol(for: pane))
            button.target = self
            button.action = #selector(navButtonClicked(_:))
            navButtons[pane] = button
            navStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navStack.widthAnchor).isActive = true
        }

        let versionLabel = PSTheme.label(
            "v\(PinShotConstants.version)",
            font: PSTheme.mono(11),
            color: PSTheme.textTertiary
        )
        let bottomStack = NSStackView(views: [sidebarStatus, versionLabel])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 5
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        sidebarView.addSubview(appIcon)
        sidebarView.addSubview(nameLabel)
        sidebarView.addSubview(taglineLabel)
        sidebarView.addSubview(navStack)
        sidebarView.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 20),
            appIcon.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 56),

            nameLabel.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 20),
            nameLabel.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 14),

            taglineLabel.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 20),
            taglineLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            navStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 10),
            navStack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -10),
            navStack.topAnchor.constraint(equalTo: taglineLabel.bottomAnchor, constant: 26),

            bottomStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(lessThanOrEqualTo: sidebarView.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -20)
        ])
    }

    private static func navTitle(for pane: Pane) -> String {
        switch pane {
        case .capture: return "截图"
        case .pin: return "贴图"
        case .launch: return "启动与权限"
        case .about: return "关于"
        }
    }

    private static func navSymbol(for pane: Pane) -> String {
        switch pane {
        case .capture: return "viewfinder"
        case .pin: return "pin.fill"
        case .launch: return "power"
        case .about: return "info.circle"
        }
    }

    // MARK: - 页面搭建

    private func buildPaneViews() {
        addPane(.capture, title: "截图", subtitle: "用两个快捷键完成截图的两种落点", cards: captureCards())
        addPane(.pin, title: "贴图", subtitle: "自动隐藏、透明度与外观", cards: pinCards())
        addPane(.launch, title: "启动与权限", subtitle: "开机启动、屏幕录制权限与维护", cards: launchCards())
        addPane(.about, title: "关于", subtitle: "PinShot · 把截图钉在屏幕最上层", cards: aboutCards())
    }

    private func addPane(_ pane: Pane, title: String, subtitle: String, cards: [NSView]) {
        let paneView = NSView()
        paneView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])

        let header = PSTheme.paneHeader(title: title, subtitle: subtitle)
        let scrollView = makeScrollView(cards: cards)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        paneView.addSubview(header)
        paneView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: paneView.leadingAnchor, constant: PSTheme.contentInset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: paneView.trailingAnchor, constant: -PSTheme.contentInset),
            header.topAnchor.constraint(equalTo: paneView.topAnchor, constant: PSTheme.contentInset),

            scrollView.leadingAnchor.constraint(equalTo: paneView.leadingAnchor, constant: PSTheme.contentInset),
            scrollView.trailingAnchor.constraint(equalTo: paneView.trailingAnchor, constant: -PSTheme.contentInset),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: PSTheme.sectionSpacing),
            scrollView.bottomAnchor.constraint(equalTo: paneView.bottomAnchor, constant: -PSTheme.contentInset)
        ])

        paneViews[pane] = paneView
        paneScrollViews[pane] = scrollView
        paneView.isHidden = true
    }

    private func makeScrollView(cards: [NSView]) -> NSScrollView {
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PSTheme.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView

        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor)
        ])
        return scrollView
    }

    // MARK: 卡片 / 行 helper

    private func makeCard(title: (symbol: String, text: String)? = nil, rows: [NSView]) -> PinCardView {
        let card = PSTheme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false

        if let title {
            let header = NSView()
            header.translatesAutoresizingMaskIntoConstraints = false
            let titleView = PSTheme.cardTitle(symbol: title.symbol, title: title.text)
            header.addSubview(titleView)
            NSLayoutConstraint.activate([
                titleView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                titleView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
                titleView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                header.heightAnchor.constraint(equalToConstant: 36)
            ])
            body.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            addSeparator(to: body)
        }

        for (index, row) in rows.enumerated() {
            if index > 0 { addSeparator(to: body) }
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4)
        ])
        return card
    }

    private func addSeparator(to stack: NSStackView) {
        let separator = PSTheme.makeSeparator()
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeRow(title: String, subtitle: String? = nil, trailing: [NSView] = []) -> SettingsRowView {
        let row = SettingsRowView(title: title, subtitle: subtitle)
        if !trailing.isEmpty { row.setTrailing(trailing) }
        return row
    }

    private func makeSliderRow(
        title: String,
        subtitle: String,
        slider: PinSlider,
        valueLabel: NSTextField
    ) -> SettingsRowView {
        let row = SettingsRowView(title: title, subtitle: subtitle)
        slider.widthAnchor.constraint(equalToConstant: 186).isActive = true
        row.trailingWidthHint = 242
        row.setTrailing([horizontalStack([slider, valueLabel])])
        return row
    }

    private func horizontalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: 页面内容

    private func captureCards() -> [NSView] {
        pinHotKeyRow = HotKeyRowView(
            title: "截图并贴图",
            subtitle: "截图后立即成为置顶挂件，可以拖动、缩放、自动隐藏。",
            combo: settings.capturePinHotKey
        )
        copyHotKeyRow = HotKeyRowView(
            title: "截图并复制",
            subtitle: "截图后直接写入剪贴板，不创建挂件。",
            combo: settings.captureCopyHotKey
        )

        pinHotKeyRow.onBeginRecording = { [weak self] in self?.copyHotKeyRow?.cancelRecording() }
        pinHotKeyRow.onCommit = { [weak self] combo in self?.commitHotKey(combo, forPin: true) }
        pinHotKeyRow.conflictProvider = { [weak self] combo in
            guard let self, self.settings.captureCopyHotKey == combo else { return nil }
            return "截图并复制"
        }
        copyHotKeyRow.onBeginRecording = { [weak self] in self?.pinHotKeyRow?.cancelRecording() }
        copyHotKeyRow.onCommit = { [weak self] combo in self?.commitHotKey(combo, forPin: false) }
        copyHotKeyRow.conflictProvider = { [weak self] combo in
            guard let self, self.settings.capturePinHotKey == combo else { return nil }
            return "截图并贴图"
        }

        let hotKeyCard = makeCard(title: ("command", "快捷键"), rows: [pinHotKeyRow, copyHotKeyRow])
        let tipsCard = makeCard(title: ("sparkles", "使用提示"), rows: [
            makeRow(title: "框选截图", subtitle: "按下快捷键后拖动框选屏幕区域，松手即刻生效；ESC 或右键取消。"),
            makeRow(title: "标注截图", subtitle: "框选完成后进入标注编辑器，可画笔 / 箭头 / 矩形 / 高亮；Enter 直接完成贴图。"),
            makeRow(title: "截图前自动隐藏旧贴图", subtitle: "已有挂件会短暂隐藏，避免被截进新图里。")
        ])
        return [hotKeyCard, tipsCard]
    }

    private func pinCards() -> [NSView] {
        let autoHideCard = makeCard(title: ("eye.slash", "自动隐藏"), rows: [
            makeRow(
                title: "自动隐藏贴图",
                subtitle: "鼠标离开后自动淡出，回到挂件位置立即恢复。",
                trailing: [autoHideSwitch]
            ),
            makeSliderRow(
                title: "隐藏延迟",
                subtitle: "鼠标离开多久后开始淡出",
                slider: delaySlider,
                valueLabel: delayValueLabel
            ),
            makeSliderRow(
                title: "幽灵透明度",
                subtitle: "隐藏时保留的可见程度",
                slider: ghostSlider,
                valueLabel: ghostValueLabel
            ),
            makeRow(
                title: "完全隐藏",
                subtitle: "淡出后完全不显示，而不是保留残影。",
                trailing: [hideEntirelySwitch]
            ),
            makeRow(
                title: "隐藏时点击穿透",
                subtitle: "隐藏状态下鼠标点击直接穿过挂件。",
                trailing: [clickThroughSwitch]
            )
        ])

        let placementCard = makeCard(title: ("desktopcomputer", "放置"), rows: [
            makeRow(
                title: "新贴图挂在桌面",
                subtitle: "放在桌面图标之上、普通窗口之下，像桌面便签；关闭则浮在所有窗口最上层。",
                trailing: [desktopPlacementSwitch]
            )
        ])

        let appearanceCard = makeCard(title: ("paintbrush", "外观"), rows: [
            makeRow(title: "贴图边框", subtitle: "1px 自适应描边", trailing: [borderSwitch]),
            makeRow(title: "贴图阴影", subtitle: "窗口投影，让挂件浮在窗口之上", trailing: [shadowSwitch])
        ])
        return [autoHideCard, placementCard, appearanceCard]
    }

    private func launchCards() -> [NSView] {
        let launchCard = makeCard(title: ("power", "启动"), rows: [
            makeRow(
                title: "登录时自动启动",
                subtitle: "登录 macOS 后在菜单栏常驻，不占用 Dock。",
                trailing: [launchAtLoginSwitch]
            )
        ])

        launchPermissionRow = makeRow(
            title: "屏幕录制权限",
            subtitle: "检查中…",
            trailing: [
                launchPermissionDot,
                openSettingsPrimaryButton,
                openSettingsSecondaryButton,
                recheckPermissionButton
            ]
        )
        let permissionCard = makeCard(title: ("lock.shield", "权限"), rows: [launchPermissionRow])

        let maintenanceCard = makeCard(title: ("arrow.counterclockwise", "维护"), rows: [
            makeRow(
                title: "恢复默认设置",
                subtitle: "快捷键、自动隐藏与外观恢复默认值；开机启动与权限不变。",
                trailing: [resetDefaultsButton]
            )
        ])
        return [launchCard, permissionCard, maintenanceCard]
    }

    private func aboutCards() -> [NSView] {
        let infoCard = makeAboutInfoCard()
        let hotKeyCard = makeCard(title: ("command", "快捷键"), rows: [
            makeRow(title: "截图并贴图", trailing: [aboutPinKeycap]),
            makeRow(title: "截图并复制", trailing: [aboutCopyKeycap])
        ])
        let designCard = makeCard(title: ("paintbrush", "设计与实现"), rows: [
            makeRow(title: "视觉语言", subtitle: "暖石墨中性色 + 信号橙，快捷键键帽与裁切角标"),
            makeRow(title: "界面组件", subtitle: "开关、滑杆、键帽与卡片均为自绘，随浅色 / 深色外观自动适配。")
        ])
        return [infoCard, hotKeyCard, designCard]
    }

    private func makeAboutInfoCard() -> PinCardView {
        let card = PSTheme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        let icon = AppIconWellView(size: 64)
        let name = PSTheme.label("PinShot", font: PSTheme.display(20, weight: .semibold), color: PSTheme.textPrimary)
        let tagline = PSTheme.label("把截图钉在屏幕最上层", font: PSTheme.text(12), color: PSTheme.textSecondary)
        let version = PSTheme.label(
            "版本 v\(PinShotConstants.version)",
            font: PSTheme.mono(11),
            color: PSTheme.textTertiary
        )
        let textStack = NSStackView(views: [name, tagline, version])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = horizontalStack([icon, textStack])
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22)
        ])
        return card
    }

    // MARK: - 导航

    @objc private func navButtonClicked(_ sender: SidebarNavButton) {
        selectPane(sender.pane)
    }

    private func selectPane(_ pane: Pane) {
        if selectedPane != pane { cancelAllRecordings() }
        selectedPane = pane
        for (candidate, view) in paneViews { view.isHidden = candidate != pane }
        for (candidate, button) in navButtons { button.isSelected = candidate == pane }
        if let scrollView = paneScrollViews[pane] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if pane == .launch { refreshPermissionState() }
    }

    private func cancelAllRecordings() {
        pinHotKeyRow?.cancelRecording()
        copyHotKeyRow?.cancelRecording()
    }

    // MARK: - 设置 → UI

    @objc private func settingsDidChange(_ notification: Notification) {
        guard window?.isVisible == true, !isApplyingUserChange else { return }
        refreshFromSettings()
    }

    private func refreshFromSettings() {
        guard !isApplyingUserChange else { return }

        if let row = pinHotKeyRow, !row.isRecording { row.refresh(combo: settings.capturePinHotKey) }
        if let row = copyHotKeyRow, !row.isRecording { row.refresh(combo: settings.captureCopyHotKey) }

        autoHideSwitch.setOn(settings.autoHideEnabled, animated: false)
        hideEntirelySwitch.setOn(settings.hideEntirely, animated: false)
        clickThroughSwitch.setOn(settings.clickThroughWhenHidden, animated: false)

        delaySlider.doubleValue = settings.autoHideDelay
        delayValueLabel.stringValue = Self.delayText(settings.autoHideDelay)
        ghostSlider.doubleValue = Double(settings.ghostAlpha)
        ghostValueLabel.stringValue = Self.percentText(settings.ghostAlpha)

        borderSwitch.setOn(settings.showPinBorder, animated: false)
        shadowSwitch.setOn(settings.showPinShadow, animated: false)
        desktopPlacementSwitch.setOn(settings.defaultPinDesktop, animated: false)

        launchAtLoginSwitch.setOn(LaunchAtLogin.isEnabled, animated: false)

        aboutPinKeycap.setText(settings.capturePinHotKey.display)
        aboutCopyKeycap.setText(settings.captureCopyHotKey.display)

        launchPermissionRow?.resetSubtitle()
        refreshPermissionState()
        updateDependentControls()
    }

    private func refreshPermissionState() {
        let granted = ScreenCapturer.hasScreenRecordingPermission()
        launchPermissionDot.isGranted = granted
        sidebarStatus.set(granted: granted)
        openSettingsPrimaryButton.isHidden = granted
        openSettingsSecondaryButton.isHidden = !granted
        launchPermissionRow?.setBaseSubtitle(
            granted ? "已授权，截图功能可用。" : "未授权，截图前需要在系统设置中勾选 PinShot。"
        )
    }

    private func updateDependentControls() {
        let autoHide = autoHideSwitch.isOn
        hideEntirelySwitch.isEnabled = autoHide
        clickThroughSwitch.isEnabled = autoHide
        delaySlider.isEnabled = autoHide
        ghostSlider.isEnabled = autoHide && !hideEntirelySwitch.isOn
        delayValueLabel.textColor = autoHide ? PSTheme.textPrimary : PSTheme.textTertiary
        ghostValueLabel.textColor = ghostSlider.isEnabled ? PSTheme.textPrimary : PSTheme.textTertiary
    }

    /// 把 UI 值写回设置时抑制通知回刷（拖动滑杆不会抖动）。
    private func applySettingsChange(_ block: () -> Void) {
        isApplyingUserChange = true
        block()
        isApplyingUserChange = false
    }

    // MARK: - 控件动作

    @objc private func autoHideToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.autoHideEnabled = sender.isOn }
        updateDependentControls()
    }

    @objc private func hideEntirelyToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.hideEntirely = sender.isOn }
        updateDependentControls()
    }

    @objc private func clickThroughToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.clickThroughWhenHidden = sender.isOn }
    }

    @objc private func borderToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.showPinBorder = sender.isOn }
    }

    @objc private func shadowToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.showPinShadow = sender.isOn }
    }

    @objc private func desktopPlacementToggled(_ sender: PinSwitch) {
        applySettingsChange { settings.defaultPinDesktop = sender.isOn }
    }

    @objc private func delaySliderChanged(_ sender: PinSlider) {
        let value = (sender.doubleValue * 10).rounded() / 10
        applySettingsChange { settings.autoHideDelay = value }
        delayValueLabel.stringValue = Self.delayText(value)
    }

    @objc private func ghostSliderChanged(_ sender: PinSlider) {
        let value = (sender.doubleValue * 100).rounded() / 100
        applySettingsChange { settings.ghostAlpha = CGFloat(value) }
        ghostValueLabel.stringValue = Self.percentText(CGFloat(value))
    }

    @objc private func launchAtLoginToggled(_ sender: PinSwitch) {
        let desired = sender.isOn
        guard LaunchAtLogin.setEnabled(desired) else {
            sender.setOn(!desired, animated: true)
            presentLaunchAtLoginFailure(desired: desired)
            return
        }
        sender.setOn(LaunchAtLogin.isEnabled, animated: true)
    }

    // MARK: - 快捷键

    private func commitHotKey(_ combo: HotKeyCombo, forPin: Bool) {
        applySettingsChange {
            if forPin {
                settings.capturePinHotKey = combo
            } else {
                settings.captureCopyHotKey = combo
            }
        }
    }

    // MARK: - 权限与维护

    @objc private func openScreenRecordingSettings(_ sender: PinButton) {
        ScreenCapturer.openScreenRecordingSettings()
    }

    @objc private func recheckPermission(_ sender: PinButton) {
        sender.isEnabled = false
        sender.titleText = "检查中…"
        Task { @MainActor in
            let ok = await ScreenCapturer.probeCapturePermission()
            sender.isEnabled = true
            sender.titleText = "重新检查"
            if ok {
                launchPermissionDot.isGranted = true
                sidebarStatus.set(granted: true)
                openSettingsPrimaryButton.isHidden = true
                openSettingsSecondaryButton.isHidden = false
                launchPermissionRow?.setBaseSubtitle("已授权，截图功能可用。")
                launchPermissionRow?.showTransientSubtitle("权限已生效，无需重启", color: PSTheme.success)
            } else {
                refreshPermissionState()
                launchPermissionRow?.showTransientSubtitle(
                    "仍未授权 · 若屏幕录制里已勾选，需删除旧 PinShot 条目并把 App 重新添加一次",
                    color: PSTheme.danger
                )
            }
        }
    }

    @objc private func resetDefaults(_ sender: PinButton) {
        // NSAlert 只用于「恢复默认」确认（改版约定：交互提示尽量行内化）
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "恢复默认设置？"
        alert.informativeText = "快捷键、自动隐藏与外观会恢复默认值；开机启动与屏幕录制权限不受影响。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applySettingsChange { settings.resetToDefaults() }
        refreshFromSettings()
    }

    private func presentLaunchAtLoginFailure(desired: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = desired ? "无法开启「登录时自动启动」" : "无法关闭「登录时自动启动」"
        alert.informativeText = """
        写入登录项失败。请检查 ~/Library/LaunchAgents 的写入权限，\
        或在「系统设置 → 通用 → 登录项」中手动管理 PinShot。
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - 渲染辅助

    private func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { markNeedsDisplay(subview) }
    }

    // MARK: - 文案格式化

    private static func delayText(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    private static func percentText(_ value: CGFloat) -> String {
        String(format: "%.0f%%", Double(value) * 100)
    }
}

// MARK: - 快捷键录制行

/// 设置卡片里的一行快捷键：标题 + 说明 + 键帽 + 录制按钮。
///
/// 点击「录制」进入行内录制态：橙色描边 + 说明行变为录制提示，键帽实时预览；
/// ESC 取消、无修饰键拒绝、与另一个快捷键冲突时行内红字提示（不弹窗）。
@MainActor
private final class HotKeyRowView: SettingsRowView {
    private let keycapSlot = KeycapSlotView(frame: .zero)
    private let recordButton = PinButton(title: "录制", style: .secondary)
    private(set) var combo: HotKeyCombo?
    private(set) var isRecording = false

    var onBeginRecording: (() -> Void)?
    var onCommit: ((HotKeyCombo) -> Void)?
    /// 返回冲突的另一个快捷键名称（nil 表示不冲突）
    var conflictProvider: ((HotKeyCombo) -> String?)?

    private var monitor: Any?

    init(title: String, subtitle: String, combo: HotKeyCombo) {
        self.combo = combo
        super.init(title: title, subtitle: subtitle)
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        recordButton.setAccessibilityLabel("录制快捷键")
        setTrailing([keycapSlot, recordButton])
        keycapSlot.setText(combo.display)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(combo: HotKeyCombo) {
        self.combo = combo
        if !isRecording { keycapSlot.setText(combo.display) }
    }

    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
    }

    @objc private func recordTapped() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        onBeginRecording?()
        isRecording = true
        setHighlight(true)
        resetSubtitle()
        showTransientSubtitle("按下新的快捷键 · ESC 取消", color: PSTheme.accent)
        setRecordButtonTitle("取消")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            var response: NSEvent?
            MainActor.assumeIsolated {
                response = self.handle(event)
            }
            return response
        }
    }

    private func finishRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        setHighlight(false)
        setRecordButtonTitle("录制")
        resetSubtitle()
        keycapSlot.setText(combo?.display ?? "未设置")
    }

    private func setRecordButtonTitle(_ title: String) {
        recordButton.titleText = title
        recordButton.setAccessibilityLabel(title == "录制" ? "录制快捷键" : "取消录制")
        recordButton.invalidateIntrinsicContentSize()
        recordButton.needsDisplay = true
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .flagsChanged:
            // 按住修饰键时实时预览键帽（例如 ⇧⌘）
            let modifiers = Self.modifierDisplay(event.modifierFlags)
            if modifiers.isEmpty {
                keycapSlot.setText(combo?.display ?? "")
            } else {
                keycapSlot.setText(modifiers)
            }
            return nil

        case .keyDown:
            if event.keyCode == 53 { // ESC 取消录制
                cancelRecording()
                return nil
            }
            guard let newCombo = HotKeyCombo.from(event: event) else {
                NSSound.beep()
                keycapSlot.setText(KeyCodeNames.name(for: UInt32(event.keyCode)))
                showTransientSubtitle("需要至少一个修饰键（F1–F20 可单独使用）", color: PSTheme.danger)
                return nil
            }
            keycapSlot.setText(newCombo.display)
            if let conflictName = conflictProvider?(newCombo) {
                NSSound.beep()
                showTransientSubtitle("\(newCombo.display) 已被「\(conflictName)」使用，请换一个组合键", color: PSTheme.danger)
                return nil
            }
            onCommit?(newCombo)
            combo = newCombo
            finishRecording()
            return nil

        default:
            return event
        }
    }

    private static func modifierDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
}

// MARK: - 设置行

/// 卡片里的一行：左侧标题/说明（说明可临时替换为提示或错误），右侧控件。
/// 行高 50pt；录制态时绘制橙色焦点描边。
@MainActor
private class SettingsRowView: NSView {
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
    private let textStack: NSStackView
    private var trailingView: NSView?
    private var isHighlighted = false

    /// 右侧控件区宽度提示（滑杆行让左侧说明提前让位）
    var trailingWidthHint: CGFloat?

    private var baseSubtitle: String
    private var isShowingTransient = false

    init(title: String, subtitle: String?) {
        titleLabel = PSTheme.rowTitle(title)
        subtitleLabel = PSTheme.rowSubtitle("")
        baseSubtitle = subtitle ?? ""
        textStack = NSStackView(views: [titleLabel, subtitleLabel])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PSTheme.rowHeight),

            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
        applySubtitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTrailing(_ views: [NSView]) {
        trailingView?.removeFromSuperview()
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -16)
        ])
        if let hint = trailingWidthHint {
            stack.widthAnchor.constraint(equalToConstant: hint).isActive = true
        }
        trailingView = stack
    }

    /// 更新基础说明文字（例如权限状态变化）。
    func setBaseSubtitle(_ text: String) {
        baseSubtitle = text
        if !isShowingTransient { applySubtitle() }
    }

    /// 临时提示（录制中 / 错误），录制结束时自动恢复基础说明。
    func showTransientSubtitle(_ text: String, color: NSColor) {
        isShowingTransient = true
        subtitleLabel.isHidden = false
        subtitleLabel.stringValue = text
        subtitleLabel.textColor = color
    }

    func resetSubtitle() {
        isShowingTransient = false
        applySubtitle()
    }

    func setHighlight(_ on: Bool) {
        guard isHighlighted != on else { return }
        isHighlighted = on
        needsDisplay = true
    }

    private func applySubtitle() {
        subtitleLabel.textColor = PSTheme.textSecondary
        subtitleLabel.stringValue = baseSubtitle
        subtitleLabel.isHidden = baseSubtitle.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        let rect = bounds.insetBy(dx: 2, dy: 5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        PSTheme.accentSoft.setFill()
        path.fill()
        PSTheme.accent.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 键帽槽位

/// 可动态更新文字键帽的容器（`KeycapView` 的文字不可变，因此更新时替换子视图）。
@MainActor
private final class KeycapSlotView: NSView {
    private var keycap: KeycapView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        keycap?.intrinsicContentSize ?? NSSize(width: 44, height: 22)
    }

    func setText(_ text: String) {
        keycap?.removeFromSuperview()
        let cap = KeycapView(text: text)
        addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: trailingAnchor),
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        keycap = cap
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

// MARK: - 侧边栏导航项

@MainActor
private final class SidebarNavButton: NSButton {
    let pane: SettingsWindowController.Pane
    private let titleText: String
    private let symbolName: String
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    init(pane: SettingsWindowController.Pane, title: String, symbol: String) {
        self.pane = pane
        self.titleText = title
        self.symbolName = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        self.title = ""
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            PSTheme.accentSoft.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        } else if isHovering {
            PSTheme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }

        let tint: NSColor = isSelected ? PSTheme.accent : (isHovering ? PSTheme.textPrimary : PSTheme.textSecondary)
        if let image = Self.symbolImage(symbolName, color: tint) {
            let imageSize = image.size
            let iconRect = NSRect(
                x: 12,
                y: (bounds.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: PSTheme.text(13, weight: isSelected ? .semibold : .medium),
            .foregroundColor: tint
        ]
        let textSize = (titleText as NSString).size(withAttributes: attributes)
        (titleText as NSString).draw(
            at: NSPoint(x: 38, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
    }

    private static func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(configuration)
    }
}

// MARK: - 侧边栏底部状态

@MainActor
private final class SidebarStatusView: NSView {
    private let dot = PermissionDotView()
    private let label = PSTheme.label("", font: PSTheme.text(11, weight: .medium), color: PSTheme.textSecondary)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(granted: Bool) {
        dot.isGranted = granted
        label.stringValue = granted ? "已授权屏幕录制" : "未授权屏幕录制"
        label.textColor = granted ? PSTheme.textSecondary : PSTheme.danger
    }
}

// MARK: - 权限状态圆点

/// 8pt 状态圆点：绿色 = 已授权，红色 = 未授权。
@MainActor
private final class PermissionDotView: NSView {
    var isGranted = false {
        didSet {
            guard isGranted != oldValue else { return }
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        let color = isGranted ? PSTheme.success : PSTheme.danger
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - App 图标块

/// 圆角 App 图标（侧边栏 56pt / 关于页 64pt）。
@MainActor
private final class AppIconWellView: NSView {
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let icon = Self.appIconImage() {
            icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            PSTheme.accentSoft.setFill()
            bounds.fill()
            if let symbol = Self.symbolImage("viewfinder", color: PSTheme.accent, pointSize: size * 0.46) {
                let symbolSize = symbol.size
                symbol.draw(
                    in: NSRect(
                        x: (bounds.width - symbolSize.width) / 2,
                        y: (bounds.height - symbolSize.height) / 2,
                        width: symbolSize.width,
                        height: symbolSize.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        PSTheme.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static func appIconImage() -> NSImage? {
        // 优先加载 bundle 内的 AppIcon.icns；脱离 .app 运行时用绘制占位，避免显示系统通用图标
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard Bundle.main.bundleIdentifier == PinShotConstants.bundleIdentifier else { return nil }
        return NSApplication.shared.applicationIconImage
    }

    private static func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(configuration)
    }
}

// MARK: - 根视图 / 滚动容器

/// 画布根视图：左侧侧边栏底色、右侧内容底色与 1px 分隔线。
@MainActor
private final class SettingsRootView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        PSTheme.contentBackground.setFill()
        bounds.fill()

        let sidebarRect = NSRect(x: 0, y: 0, width: PSTheme.sidebarWidth, height: bounds.height)
        PSTheme.sidebarBackground.setFill()
        sidebarRect.fill()

        PSTheme.separator.setFill()
        NSRect(x: PSTheme.sidebarWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 滚动视图 documentView：翻转坐标系，让卡片从顶部开始排列。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 兼容入口

/// 同时提供顶层 `Pane` 与 `SettingsWindowController.Pane` 两种写法，
/// 便于 `--render-ui` 等调试代码直接引用。
typealias Pane = SettingsWindowController.Pane
