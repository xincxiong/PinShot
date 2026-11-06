import AppKit

// MARK: - 卡片 / 分隔线

/// 圆角卡片：背景 + 1pt 边框，无阴影。
@MainActor
final class PinCardView: NSView {
    var cornerRadius: CGFloat = PSTheme.cardRadius {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        PSTheme.cardBackground.setFill()
        path.fill()
        PSTheme.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 1px 分隔线。
@MainActor
final class ColorLineView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

// MARK: - 快捷键键帽

/// 等宽快捷键键帽，例如 ⇧⌘2。
@MainActor
final class KeycapView: NSView {
    private let text: String
    private let font: NSFont

    init(text: String, fontSize: CGFloat = 11) {
        self.text = text
        self.font = PSTheme.mono(fontSize, weight: .medium)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(text)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var textSize: NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    override var intrinsicContentSize: NSSize {
        let size = textSize
        return NSSize(width: ceil(size.width) + 16, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        PSTheme.keycapBackground.setFill()
        path.fill()
        PSTheme.keycapBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PSTheme.textPrimary
        ]
        let size = textSize
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

// MARK: - 图标徽章

/// 圆角方形图标底，用于导航 / 卡片标题。
@MainActor
final class IconBadgeView: NSView {
    private let symbol: String
    private let tint: NSColor
    private let size: CGFloat

    init(symbol: String, tint: NSColor, size: CGFloat) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = size * 0.28
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        tint.withAlphaComponent(0.13).setFill()
        path.fill()

        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
        let configured = image.withSymbolConfiguration(configuration) ?? image
        let imageSize = configured.size
        let rect = NSRect(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        configured.isTemplate = true
        tint.setFill()
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

// MARK: - 按钮

/// 定制按钮：主按钮 / 次按钮 / 文字按钮，带 hover 与按下反馈。
@MainActor
final class PinButton: NSButton {
    enum Style {
        case primary
        case secondary
        case text
    }

    let style: Style
    var titleText: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var buttonFont: NSFont = PSTheme.text(13, weight: .semibold) {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var contentInset = NSSize(width: 18, height: 9)
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(title: String, style: Style) {
        self.style = style
        self.titleText = title
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
        switch style {
        case .primary, .secondary:
            buttonFont = PSTheme.text(13, weight: .semibold)
        case .text:
            buttonFont = PSTheme.text(12, weight: .medium)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let textWidth = (titleText as NSString).size(withAttributes: [.font: buttonFont]).width
        if style == .text {
            return NSSize(width: ceil(textWidth) + 12, height: 24)
        }
        let textHeight = (titleText as NSString).size(withAttributes: [.font: buttonFont]).height
        return NSSize(width: ceil(textWidth) + contentInset.width * 2, height: ceil(textHeight) + contentInset.height * 2)
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
        let pressed = isHighlighted
        let enabled = isEnabled

        let attributes: [NSAttributedString.Key: Any] = [
            .font: buttonFont,
            .foregroundColor: textColor(pressed: pressed, enabled: enabled)
        ]

        switch style {
        case .primary:
            let bg = enabled
                ? (pressed || isHovering ? PSTheme.accentFillHover : PSTheme.accentFill)
                : PSTheme.textTertiary.withAlphaComponent(0.35)
            bg.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: PSTheme.controlRadius + 1, yRadius: PSTheme.controlRadius + 1).fill()
        case .secondary:
            PSTheme.keycapBackground.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: PSTheme.controlRadius, yRadius: PSTheme.controlRadius)
            path.fill()
            PSTheme.keycapBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            let overlay = pressed ? PSTheme.pressedFill : (isHovering ? PSTheme.hoverFill : NSColor.clear)
            overlay.setFill()
            path.fill()
        case .text:
            if isHovering || pressed {
                (pressed ? PSTheme.pressedFill : PSTheme.accentSoft).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
        }

        let size = (titleText as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (titleText as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func textColor(pressed: Bool, enabled: Bool) -> NSColor {
        guard enabled else { return PSTheme.textTertiary }
        switch style {
        case .primary:
            return .white
        case .secondary:
            return PSTheme.textPrimary
        case .text:
            return (isHovering || pressed) ? PSTheme.accentHover : PSTheme.accent
        }
    }
}

// MARK: - 开关

/// 定制胶囊开关：信号橙开启态、白色滑块、0.14s 位移动画。
@MainActor
final class PinSwitch: NSControl {
    private(set) var isOn: Bool = false
    private let knob = NSView()
    private let knobSize: CGFloat = 18
    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private var labelText: String = ""

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            needsDisplay = true
        }
    }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        knob.wantsLayer = true
        knob.layer?.backgroundColor = NSColor.white.cgColor
        knob.layer?.cornerRadius = knobSize / 2
        knob.layer?.shadowColor = NSColor.black.cgColor
        knob.layer?.shadowOpacity = 0.18
        knob.layer?.shadowRadius = 2
        knob.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(knob)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("开关")
        refreshKnobFrame(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLabel(_ label: String) {
        labelText = label
        setAccessibilityLabel(label)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: height) }

    func setOn(_ on: Bool, animated: Bool) {
        guard isOn != on else { return }
        isOn = on
        setAccessibilityValue(on as NSNumber)
        refreshKnobFrame(animated: animated)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        refreshKnobFrame(animated: false)
    }

    private func refreshKnobFrame(animated: Bool) {
        let inset: CGFloat = 2
        let x = isOn ? bounds.width - knobSize - inset : inset
        let frame = NSRect(x: x, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                knob.animator().frame = frame
            }
        } else {
            knob.frame = frame
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            PSTheme.accent.setFill()
        } else {
            PSTheme.dynamic(
                light: PSTheme.hex(0xDCD8D1),
                dark: PSTheme.hex(0x3A352F)
            ).setFill()
        }
        track.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setOn(!isOn, animated: true)
        sendAction(action, to: target)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Space
            guard isEnabled else { return }
            setOn(!isOn, animated: true)
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 滑杆

/// 定制滑杆：4pt 轨道 + 橙色已填充部分 + 白色滑块。
@MainActor
final class PinSlider: NSControl {
    var minValue: Double = 0
    var maxValue: Double = 1
    private var storedValue: Double = 0
    override var doubleValue: Double {
        get { storedValue }
        set {
            storedValue = min(max(newValue, minValue), maxValue)
            needsDisplay = true
        }
    }

    private let knobSize: CGFloat = 18
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45; needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.slider)
        setAccessibilityLabel("滑杆")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: knobSize + 6)
    }

    override func layout() {
        super.layout()
    }

    private var fraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((doubleValue - minValue) / (maxValue - minValue))
    }

    private var trackRect: NSRect {
        NSRect(x: knobSize / 2, y: (bounds.height - 4) / 2, width: max(1, bounds.width - knobSize), height: 4)
    }

    private var knobRect: NSRect {
        let track = trackRect
        let x = track.minX + track.width * fraction - knobSize / 2
        return NSRect(x: x, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
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
        guard !isDragging else { return }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let trackPath = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        PSTheme.dynamic(light: PSTheme.hex(0xE3DFD8), dark: PSTheme.hex(0x3A352F)).setFill()
        trackPath.fill()

        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        if filled.width > 0 {
            let fillPath = NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2)
            (isEnabled ? PSTheme.accent : PSTheme.textTertiary).setFill()
            fillPath.fill()
        }

        let knob = knobRect
        let knobPath = NSBezierPath(ovalIn: knob)
        NSColor.white.setFill()
        knobPath.fill()
        PSTheme.dynamic(light: PSTheme.hex(0xE0DCD4), dark: PSTheme.hex(0x4C463E)).setStroke()
        knobPath.lineWidth = 1
        knobPath.stroke()

        if isHovering || isDragging {
            PSTheme.accent.withAlphaComponent(0.22).setStroke()
            let ring = NSBezierPath(ovalIn: knob.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        updateValue(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
    }

    private func updateValue(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let track = trackRect
        let fraction = min(max((point.x - track.minX) / max(track.width, 1), 0), 1)
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
        setAccessibilityValue(doubleValue as NSNumber)
        sendAction(action, to: target)
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        let step = (maxValue - minValue) / 100
        switch event.keyCode {
        case 123:
            doubleValue -= step
        case 124:
            doubleValue += step
        default:
            super.keyDown(with: event)
            return
        }
        sendAction(action, to: target)
    }
}
