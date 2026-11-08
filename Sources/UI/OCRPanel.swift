import AppKit

/// 识别结果面板：离线 OCR 后展示可选中文本，一键复制全文。
/// 单例复用；由标注编辑器 / 贴图窗口调用。
@MainActor
final class OCRPanelController: NSWindowController, NSWindowDelegate {

    static let shared = OCRPanelController()

    private let content = OCRPanelContentView()
    private let panel: OCRPanel
    private var keyMonitor: Any?
    private var currentText = ""
    private var currentBarcodes: [String] = []
    private var sourceTitle = "识别文字"
    private var isRecognizing = false

    private init() {
        panel = OCRPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别文字"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = OCRPanelTheme.background
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = content
        content.onCopy = { [weak self] in self?.copyAll() }
        content.onClose = { [weak self] in self?.closePanel() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 对外

    func present(image: PinnedImage, title: String = "识别文字") {
        sourceTitle = title
        currentText = ""
        isRecognizing = true
        content.show(text: "", status: "正在识别截图中的文字…", busy: true, copyEnabled: false)
        panel.title = title
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        installKeyMonitor()

        let cgImage = image.cgImage
        TextRecognizer.recognize(cgImage: cgImage) { [weak self] result in
            guard let self else { return }
            self.isRecognizing = false
            if let error = result.errorMessage {
                self.content.show(text: "", status: "识别失败：\(error)", busy: false, copyEnabled: false)
                return
            }
            self.currentText = result.text
            self.currentBarcodes = result.barcodes
            if result.isEmpty {
                self.content.show(text: "", status: "没有识别到文字，可以换一张更清晰的截图试试。", busy: false, copyEnabled: false)
            } else {
                let chars = result.text.count
                self.content.show(
                    text: result.text,
                    status: "已识别 \(result.lineCount) 行 · \(chars) 个字符 · 可直接选择或复制全文",
                    busy: false,
                    copyEnabled: true
                )
            }
        }
    }

    /// 直接展示已经识别好的文字（标注编辑器自动 OCR 的结果），不再重复识别。
    func present(text: String, title: String = "识别文字") {
        sourceTitle = title
        currentText = text
        currentBarcodes = []
        isRecognizing = false
        panel.title = title
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        installKeyMonitor()
        if text.isEmpty {
            content.show(text: "", status: "没有识别到文字，可以换一张更清晰的截图试试。", busy: false, copyEnabled: false)
        } else {
            content.show(
                text: text,
                status: "已识别 \(text.count) 个字符 · 可直接选择或复制全文",
                busy: false,
                copyEnabled: true
            )
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    // MARK: - 复制

    private func copyAll() {
        guard !currentText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentText, forType: .string)
        content.flashCopied()
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.keyCode == 53 { // Esc
                self.closePanel()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                // 文本视图里已有选区时让系统复制选区；否则复制全文。
                if self.content.hasSelection { return event }
                self.copyAll()
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }
}

// MARK: - 面板

private final class OCRPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum OCRPanelTheme {
    static let background = NSColor(srgbRed: 0x18 / 255, green: 0x1a / 255, blue: 0x1c / 255, alpha: 1)
    static let surface = NSColor(srgbRed: 0x21 / 255, green: 0x24 / 255, blue: 0x27 / 255, alpha: 1)
    static let border = NSColor.white.withAlphaComponent(0.10)
    static let text = NSColor(srgbRed: 0xf4 / 255, green: 0xf1 / 255, blue: 0xea / 255, alpha: 1)
    static let secondary = NSColor(srgbRed: 0xa8 / 255, green: 0xa2 / 255, blue: 0x98 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xe8 / 255, green: 0x55 / 255, blue: 0x1f / 255, alpha: 1)
}

/// 手写布局的面板内容视图：标题 / 可选中文本 / 状态 / 复制与关闭。
@MainActor
private final class OCRPanelContentView: NSView {

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "识别文字")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = PinButton(title: "复制全文", style: .primary)
    private let closeButton = PinButton(title: "关闭", style: .secondary)
    private let barcodeButton = PinButton(title: "复制二维码", style: .secondary)
    private let emptyLabel = NSTextField(labelWithString: "没有识别到文字")
    private let spinner = NSProgressIndicator()

    var hasSelection: Bool {
        textView.selectedRange().length > 0
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OCRPanelTheme.background.cgColor

        titleLabel.font = PSTheme.text(15, weight: .semibold)
        titleLabel.textColor = OCRPanelTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = PSTheme.text(11.5)
        subtitleLabel.textColor = OCRPanelTheme.secondary
        subtitleLabel.lineBreakMode = .byTruncatingTail

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = OCRPanelTheme.text
        textView.font = NSFont.systemFont(ofSize: 13.5)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = OCRPanelTheme.surface.cgColor
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = OCRPanelTheme.border.cgColor

        statusLabel.font = PSTheme.text(11)
        statusLabel.textColor = OCRPanelTheme.secondary
        statusLabel.lineBreakMode = .byTruncatingTail

        emptyLabel.font = PSTheme.text(12)
        emptyLabel.textColor = OCRPanelTheme.secondary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.buttonFont = PSTheme.text(12.5, weight: .semibold)
        copyButton.contentInset = NSSize(width: 16, height: 7)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.buttonFont = PSTheme.text(12.5)
        closeButton.contentInset = NSSize(width: 14, height: 7)

        barcodeButton.target = self
        barcodeButton.action = #selector(copyBarcodeTapped)
        barcodeButton.buttonFont = PSTheme.text(12.5)
        barcodeButton.contentInset = NSSize(width: 12, height: 7)
        barcodeButton.isHidden = true

        for view in [titleLabel, subtitleLabel, scrollView, statusLabel, copyButton, closeButton, barcodeButton, spinner] {
            addSubview(view)
        }
        addSubview(emptyLabel) // 放到 scrollView 之上
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let inset: CGFloat = 22

        titleLabel.frame = NSRect(x: inset, y: height - 46, width: width - inset * 2 - 90, height: 22)
        subtitleLabel.frame = NSRect(x: inset, y: height - 68, width: width - inset * 2 - 90, height: 18)
        spinner.frame = NSRect(x: width - inset - 18, y: height - 54, width: 18, height: 18)

        let bottomBarHeight: CGFloat = 48
        scrollView.frame = NSRect(
            x: inset,
            y: bottomBarHeight + 18,
            width: width - inset * 2,
            height: max(60, height - 68 - bottomBarHeight - 30)
        )
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)

        emptyLabel.frame = NSRect(
            x: scrollView.frame.minX + 20,
            y: scrollView.frame.midY - 10,
            width: scrollView.frame.width - 40,
            height: 20
        )

        closeButton.frame = NSRect(x: width - inset - 68, y: 14, width: 68, height: 28)
        copyButton.frame = NSRect(x: width - inset - 68 - 8 - 88, y: 14, width: 88, height: 28)
        barcodeButton.frame = NSRect(x: width - inset - 68 - 8 - 88 - 8 - 96, y: 14, width: 96, height: 28)
        let statusRight = barcodeButton.isHidden
            ? width - inset - 68 - 88 - 8 - 8
            : barcodeButton.frame.minX - 8
        statusLabel.frame = NSRect(
            x: inset,
            y: 18,
            width: max(80, statusRight - inset),
            height: 18
        )
    }

    // MARK: - 状态

    private var barcodes: [String] = []

    func show(text: String, status: String, busy: Bool, copyEnabled: Bool, barcodes: [String] = []) {
        self.barcodes = barcodes
        barcodeButton.isHidden = barcodes.isEmpty
        barcodeButton.titleText = "复制二维码"
        textView.string = text
        statusLabel.stringValue = status
        copyButton.isEnabled = copyEnabled
        copyButton.titleText = "复制全文"
        emptyLabel.isHidden = !text.isEmpty || busy
        emptyLabel.stringValue = status.contains("失败") ? "识别失败" : "没有识别到文字"
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        needsLayout = true
        if !text.isEmpty {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            window?.makeFirstResponder(textView)
        }
    }

    func flashCopied() {
        copyButton.titleText = "已复制 ✓"
        copyButton.isEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.titleText = "复制全文"
        }
    }

    // MARK: - 动作

    @objc private func copyTapped() { onCopy?() }

    @objc private func copyBarcodeTapped() {
        guard !barcodes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(barcodes.joined(separator: "\n"), forType: .string)
        barcodeButton.titleText = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.barcodeButton.titleText = "复制二维码"
        }
    }

    @objc private func closeTapped() { onClose?() }
}
