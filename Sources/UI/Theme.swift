import AppKit

/// PinShot 设计系统：颜色、字体、尺寸、常用组件。
///
/// 视觉方向：暖石墨中性色 + 信号橙（取自 App 图标里的图钉），
/// 大圆角卡片、无重边框、等宽快捷键键帽、圆体标题。
/// 所有动态颜色都会随系统浅色 / 深色自动切换。
@MainActor
enum PSTheme {

    // MARK: - 调色板（动态：浅色 / 深色）

    static let contentBackground = dynamic(light: hex(0xF4F3F0), dark: hex(0x171614))
    static let sidebarBackground = dynamic(light: hex(0xECEAE5), dark: hex(0x201E1B))
    static let cardBackground = dynamic(light: hex(0xFCFBF9), dark: hex(0x24221E))
    static let cardBorder = dynamic(light: hex(0xE4E1DA), dark: hex(0x36322C))
    static let separator = dynamic(light: hex(0xEDEAE4), dark: hex(0x302C27))

    static let textPrimary = dynamic(light: hex(0x1D1B18), dark: hex(0xF2EFE9))
    static let textSecondary = dynamic(light: hex(0x75716A), dark: hex(0xA9A297))
    static let textTertiary = dynamic(light: hex(0x99948B), dark: hex(0x7E776C))

    /// 信号橙：选中态、主按钮、强调数字
    static let accent = dynamic(light: hex(0xE8551F), dark: hex(0xFF7A45))
    static let accentHover = dynamic(light: hex(0xD4470F), dark: hex(0xFF8F62))
    /// 主按钮填充：两种外观下都用同一深橙，保证白字对比度
    static let accentFill = hex(0xE8551F)
    static let accentFillHover = hex(0xD4470F)
    static let accentSoft = dynamic(light: hex(0xE8551F).withAlphaComponent(0.12), dark: hex(0xFF7A45).withAlphaComponent(0.16))

    static let keycapBackground = dynamic(light: hex(0xF0EDE7), dark: hex(0x2B2823))
    static let keycapBorder = dynamic(light: hex(0xDDD8CF), dark: hex(0x3C3730))

    static let success = dynamic(light: hex(0x2C9A62), dark: hex(0x4CC38A))
    static let danger = dynamic(light: hex(0xD2453F), dark: hex(0xFF6B62))
    static let warning = dynamic(light: hex(0xC98A13), dark: hex(0xE6B450))

    static let hoverFill = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.08))
    static let pressedFill = dynamic(light: NSColor.black.withAlphaComponent(0.09), dark: NSColor.white.withAlphaComponent(0.13))

    // MARK: - 字体

    /// 圆体标题（macOS 系统 SF Rounded）
    static func display(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    static func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 快捷键、数字、单位
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - 尺寸

    static let settingsWindowSize = NSSize(width: 820, height: 600)
    static let sidebarWidth: CGFloat = 220
    static let contentInset: CGFloat = 32
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    static let rowHeight: CGFloat = 50
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 22

    // MARK: - 颜色工具

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    // MARK: - 文本

    static func label(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.usesSingleLineMode = true
        return field
    }

    static func rowTitle(_ string: String) -> NSTextField {
        label(string, font: text(13, weight: .medium), color: textPrimary)
    }

    static func rowSubtitle(_ string: String) -> NSTextField {
        label(string, font: text(11), color: textSecondary)
    }

    static func caption(_ string: String) -> NSTextField {
        label(string, font: text(11), color: textTertiary)
    }

    /// 面板大标题（侧边栏导航对应页的标题）
    static func paneHeader(title: String, subtitle: String) -> NSView {
        let titleLabel = label(title, font: display(22, weight: .semibold), color: textPrimary)
        let subtitleLabel = label(subtitle, font: text(12), color: textSecondary)
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// 卡片内的小标题（图标 + 12pt 半粗）
    static func cardTitle(symbol: String, title: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = textSecondary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let textLabel = label(title, font: self.text(12, weight: .semibold), color: textSecondary)
        let stack = NSStackView(views: [icon, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - 卡片

    /// 圆角卡片容器（背景 + 1pt 边框，无阴影，保持轻盈）
    static func makeCard() -> PinCardView {
        PinCardView()
    }

    static func makeSeparator() -> NSView {
        let line = ColorLineView(color: separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// 标准设置行：左侧标题/副标题，右侧控件；行高 50
    static func makeRow(title: String, subtitle: String? = nil, trailing: NSView?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = rowTitle(title)
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        if let subtitle {
            textStack.addArrangedSubview(rowSubtitle(subtitle))
        }

        row.addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10)
        ])

        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(trailing)
            NSLayoutConstraint.activate([
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailing.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 16)
            ])
        } else {
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }

        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        return row
    }

    // MARK: - 组件

    static func makeKeycap(_ text: String) -> KeycapView {
        KeycapView(text: text)
    }

    static func makeIconBadge(symbol: String, tint: NSColor? = nil, size: CGFloat = 28) -> IconBadgeView {
        IconBadgeView(symbol: symbol, tint: tint ?? accent, size: size)
    }

    static func makeButton(
        title: String,
        style: PinButton.Style,
        target: AnyObject?,
        action: Selector
    ) -> PinButton {
        let button = PinButton(title: title, style: style)
        button.target = target
        button.action = action
        return button
    }
}
