import AppKit

/// 统一封装系统分享面板（NSSharingServicePicker）：AirDrop / 信息 / 邮件 / 备忘录等。
@MainActor
enum ShareService {
    private static var currentPicker: NSSharingServicePicker?

    /// 从某个视图弹出分享面板。`view` 只用于定位，不要求是按钮。
    static func share(image: NSImage, from view: NSView, preferredEdge: NSRectEdge = .maxY) {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: [image])
        currentPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
        // NSSharingServicePicker 由系统菜单持有；这里保留一段时间，避免被提前释放。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if currentPicker === picker { currentPicker = nil }
        }
    }

    static func share(pinnedImage: PinnedImage, from view: NSView, preferredEdge: NSRectEdge = .maxY) {
        share(image: pinnedImage.nsImage, from: view, preferredEdge: preferredEdge)
    }
}
