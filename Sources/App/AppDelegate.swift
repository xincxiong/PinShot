import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let settings = AppSettings.shared
    private let coordinator = CaptureCoordinator.shared
    private let hotKeyManager = GlobalHotKeyManager.shared

    private enum MenuTag: Int {
        case capturePin = 100
        case captureCopy
        case clipboardPin
        case windowCapture
        case fullScreen
        case scrollCapture
        case gifCapture
        case delayCapture
        case delay3
        case delay5
        case delay10
        case repeatLast
        case toggleAllPins
        case closeAllPins
        case allDesktop
        case allFloating
        case autoHide
        case pauseAutoHide
        case settings
        case permission
        case guide
        case about
        case quit
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupHotKeys()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .pinShotSettingsDidChange,
            object: nil
        )
        PinManager.shared.onPinsChanged = { [weak self] in
            self?.refreshStatusItemTooltip()
        }
        refreshStatusItemTooltip()

        DebugDemo.handleLaunchArguments()

        if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showWelcomeGuideIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager.unregisterAll()
        PinManager.shared.closeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinShot")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "📌" : ""
            button.imagePosition = .imageOnly
        }

        menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeItem(title: "截图并贴图", action: #selector(capturePinAction), tag: .capturePin, symbol: "viewfinder"))
        menu.addItem(makeItem(title: "截图并复制", action: #selector(captureCopyAction), tag: .captureCopy, symbol: "doc.on.doc"))
        menu.addItem(makeItem(title: "从剪贴板贴图…", action: #selector(clipboardPinAction), tag: .clipboardPin, symbol: "doc.on.clipboard"))
        menu.addItem(makeItem(title: "窗口截图", action: #selector(windowCaptureAction), tag: .windowCapture, symbol: "macwindow"))
        menu.addItem(makeItem(title: "全屏截图", action: #selector(fullScreenAction), tag: .fullScreen, symbol: "rectangle.inset.filled"))
        menu.addItem(makeItem(title: "滚动截图", action: #selector(scrollCaptureAction), tag: .scrollCapture, symbol: "arrow.up.and.down.text.horizontal"))
        menu.addItem(makeItem(title: "录制 GIF", action: #selector(gifCaptureAction), tag: .gifCapture, symbol: "record.circle"))
        let delayItem = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        delayItem.tag = MenuTag.delayCapture.rawValue
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        delayItem.image?.isTemplate = true
        let delayMenu = NSMenu()
        delayMenu.addItem(makeItem(title: "3 秒后框选", action: #selector(delay3Action), tag: .delay3))
        delayMenu.addItem(makeItem(title: "5 秒后框选", action: #selector(delay5Action), tag: .delay5))
        delayMenu.addItem(makeItem(title: "10 秒后框选", action: #selector(delay10Action), tag: .delay10))
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)
        menu.addItem(makeItem(title: "重复上次区域", action: #selector(repeatLastAction), tag: .repeatLast, symbol: "arrow.clockwise"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "隐藏全部贴图", action: #selector(toggleAllPinsAction), tag: .toggleAllPins, symbol: "eye.slash"))
        menu.addItem(makeItem(title: "关闭全部贴图", action: #selector(closeAllPinsAction), tag: .closeAllPins, symbol: "xmark.circle"))
        menu.addItem(makeItem(title: "全部贴到桌面", action: #selector(allDesktopAction), tag: .allDesktop, symbol: "desktopcomputer"))
        menu.addItem(makeItem(title: "全部浮到顶层", action: #selector(allFloatingAction), tag: .allFloating, symbol: "pin.fill"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "自动隐藏贴图", action: #selector(toggleAutoHideAction), tag: .autoHide, symbol: "eye"))
        menu.addItem(makeItem(title: "暂停自动隐藏", action: #selector(togglePauseAutoHideAction), tag: .pauseAutoHide, symbol: "pause.circle"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "设置…", action: #selector(openSettingsAction), tag: .settings, keyEquivalent: ",", symbol: "gearshape"))
        menu.addItem(makeItem(title: "屏幕录制权限…", action: #selector(showPermissionAction), tag: .permission, symbol: "lock.shield"))
        menu.addItem(makeItem(title: "使用引导…", action: #selector(showGuideAction), tag: .guide, symbol: "sparkles"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "关于 PinShot", action: #selector(aboutAction), tag: .about, symbol: "info.circle"))
        menu.addItem(makeItem(title: "退出 PinShot", action: #selector(quitAction), tag: .quit, keyEquivalent: "q", symbol: "power"))

        statusItem.menu = menu
    }

    private func makeItem(
        title: String,
        action: Selector,
        tag: MenuTag,
        keyEquivalent: String = "",
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.tag = tag.rawValue
        item.target = self
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            item.image = image
        }
        return item
    }

    private func item(with tag: MenuTag) -> NSMenuItem? {
        menu.item(withTag: tag.rawValue)
    }

    // MARK: - 菜单刷新

    func menuWillOpen(_ menu: NSMenu) {
        item(with: .capturePin)?.title = "截图并贴图    \(settings.capturePinHotKey.display)"
        item(with: .captureCopy)?.title = "截图并复制    \(settings.captureCopyHotKey.display)"

        let allItem = item(with: .toggleAllPins)
        allItem?.title = PinManager.shared.allForcedHidden ? "显示全部贴图" : "隐藏全部贴图"
        allItem?.isEnabled = PinManager.shared.pinCount > 0
        item(with: .repeatLast)?.isEnabled = coordinator.hasLastSelection
        item(with: .closeAllPins)?.isEnabled = PinManager.shared.pinCount > 0
        item(with: .allDesktop)?.isEnabled = PinManager.shared.pinCount > 0
        item(with: .allFloating)?.isEnabled = PinManager.shared.pinCount > 0

        item(with: .autoHide)?.state = settings.autoHideEnabled ? .on : .off
        item(with: .pauseAutoHide)?.state = settings.autoHidePaused ? .on : .off
        item(with: .autoHide)?.isEnabled = !settings.autoHidePaused

        let hasPermission = ScreenCapturer.hasScreenRecordingPermission()
        if let permissionItem = item(with: .permission) {
            permissionItem.title = hasPermission ? "屏幕录制权限：已授权" : "屏幕录制权限：未授权（点击设置）"
        }
    }

    // MARK: - 菜单动作

    @objc private func capturePinAction() {
        coordinator.begin(mode: .pin)
    }

    @objc private func captureCopyAction() {
        coordinator.begin(mode: .clipboard)
    }

    @objc private func clipboardPinAction() {
        coordinator.beginFromClipboard()
    }

    @objc private func windowCaptureAction() {
        coordinator.beginWindowCapture()
    }

    @objc private func fullScreenAction() {
        coordinator.beginFullScreen()
    }

    @objc private func scrollCaptureAction() {
        coordinator.beginScrollCapture()
    }

    @objc private func gifCaptureAction() {
        coordinator.beginGIFRecording()
    }

    @objc private func delay3Action() {
        coordinator.beginDelayed(seconds: 3)
    }

    @objc private func delay5Action() {
        coordinator.beginDelayed(seconds: 5)
    }

    @objc private func delay10Action() {
        coordinator.beginDelayed(seconds: 10)
    }

    @objc private func repeatLastAction() {
        coordinator.repeatLastSelection()
    }

    @objc private func toggleAllPinsAction() {
        PinManager.shared.toggleForcedHidden()
    }

    @objc private func closeAllPinsAction() {
        PinManager.shared.closeAll()
    }

    @objc private func allDesktopAction() {
        PinManager.shared.setAllPlacement(.desktop)
    }

    @objc private func allFloatingAction() {
        PinManager.shared.setAllPlacement(.floating)
    }

    @objc private func toggleAutoHideAction() {
        settings.autoHideEnabled.toggle()
    }

    @objc private func togglePauseAutoHideAction() {
        settings.autoHidePaused.toggle()
    }

    @objc private func openSettingsAction() {
        SettingsWindowController.shared.show(pane: .capture)
    }

    @objc private func showPermissionAction() {
        CaptureCoordinator.showPermissionGuide(force: true)
    }

    @objc private func showGuideAction() {
        OnboardingWindowController.shared.present()
    }

    @objc private func aboutAction() {
        SettingsWindowController.shared.show(pane: .about)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - 全局快捷键

    private func setupHotKeys() {
        hotKeyManager.onAction = { [weak self] hotKeyID in
            guard let self else { return }
            switch hotKeyID {
            case 1: self.coordinator.begin(mode: .pin)
            case 2: self.coordinator.begin(mode: .clipboard)
            default: break
            }
        }
        registerHotKeys()
    }

    private func registerHotKeys() {
        let pinOK = hotKeyManager.register(settings.capturePinHotKey, id: 1)
        let copyOK = hotKeyManager.register(settings.captureCopyHotKey, id: 2)
        if !pinOK || !copyOK {
            NSLog("[PinShot] 快捷键注册失败，可能与其他应用冲突")
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String else { return }
        if key == "capturePinHotKey" || key == "captureCopyHotKey" {
            registerHotKeys()
        }
        if [
            "autoHideEnabled", "autoHideDelay", "ghostAlpha", "hideEntirely",
            "clickThroughWhenHidden", "autoHidePaused"
        ].contains(key) {
            AutoHideManager.shared.refreshAll()
        }
        refreshStatusItemTooltip()
    }

    private func refreshStatusItemTooltip() {
        let count = PinManager.shared.pinCount
        let base = "PinShot · \(settings.capturePinHotKey.display) 截图并贴图"
        statusItem.button?.toolTip = count > 0 ? "\(base) · \(count) 个贴图" : base
    }

    // MARK: - 首次使用引导

    private func showWelcomeGuideIfNeeded() {
        guard !settings.hasCompletedOnboarding else { return }
        settings.hasCompletedOnboarding = true

        OnboardingWindowController.shared.present()
    }
}
