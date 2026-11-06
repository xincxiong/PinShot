import AppKit

/// 管理所有置顶挂件（Pin）的生命周期。
@MainActor
final class PinManager {
    static let shared = PinManager()

    private(set) var pins: [PinWindowController] = []
    /// 菜单里的「隐藏全部」状态
    private(set) var allForcedHidden = false

    /// 贴图数量变化 / 隐藏全部状态变化时回调（用于刷新菜单）
    var onPinsChanged: (() -> Void)?

    private var hiddenForCapture: [PinWindowController] = []

    private init() {}

    var pinCount: Int { pins.count }

    // MARK: - 增删

    @discardableResult
    func addPin(_ image: PinnedImage, at globalRect: CGRect, placement: PinPlacement? = nil) -> PinWindowController {
        let frame = adjustedInitialFrame(globalRect, imageSize: image.pointSize)
        let resolvedPlacement = placement ?? (AppSettings.shared.defaultPinDesktop ? .desktop : .floating)
        let pin = PinWindowController(image: image, frame: frame)
        pin.setPlacement(resolvedPlacement, animated: false)
        pin.onClose = { [weak self] closedPin in
            self?.remove(closedPin)
        }
        pins.append(pin)
        AutoHideManager.shared.register(pin)
        pin.show()
        NSLog("[PinShot] pin added frame=\(frame) placement=\(resolvedPlacement.rawValue) total=\(pins.count)")
        if allForcedHidden {
            allForcedHidden = false
            for other in pins where other !== pin {
                other.setForcedHidden(false)
            }
        }
        onPinsChanged?()
        return pin
    }

    func remove(_ pin: PinWindowController) {
        AutoHideManager.shared.unregister(pin)
        pins.removeAll { $0 === pin }
        NSLog("[PinShot] pin removed, remaining=\(pins.count)")
        if pins.isEmpty { allForcedHidden = false }
        onPinsChanged?()
    }

    func closeAll() {
        let current = pins
        pins.removeAll()
        for pin in current {
            AutoHideManager.shared.unregister(pin)
            pin.closePin()
        }
        allForcedHidden = false
        onPinsChanged?()
    }

    func bringToFront(_ pin: PinWindowController) {
        pin.window?.orderFrontRegardless()
    }

    /// 菜单：全部贴到桌面 / 全部浮到顶层
    func setAllPlacement(_ placement: PinPlacement) {
        for pin in pins {
            pin.setPlacement(placement, animated: true)
        }
        onPinsChanged?()
    }

    // MARK: - 菜单：隐藏 / 显示全部

    @discardableResult
    func toggleForcedHidden() -> Bool {
        guard !pins.isEmpty else { return false }
        allForcedHidden.toggle()
        for pin in pins {
            pin.setForcedHidden(allForcedHidden)
        }
        onPinsChanged?()
        return allForcedHidden
    }

    // MARK: - 截图前临时隐藏

    func hideAllForCapture() {
        hiddenForCapture = pins.filter { pin in
            guard !pin.isForcedHidden else { return false }
            guard let window = pin.window, window.isVisible else { return false }
            window.orderOut(nil)
            return true
        }
    }

    func restoreAfterCapture() {
        let pinsToRestore = hiddenForCapture
        hiddenForCapture.removeAll()
        for pin in pinsToRestore where pins.contains(where: { $0 === pin }) {
            pin.show()
        }
        AutoHideManager.shared.refreshAll()
    }

    // MARK: - 初始位置

    /// 贴图窗口的初始 frame 使用选区位置（所见即所得）；
    /// 若选区贴到屏幕边缘外（例如在屏幕外松开鼠标），则收敛到最近的屏幕。
    private func adjustedInitialFrame(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let screens = NSScreen.screens
        if let screen = screens.first(where: { $0.frame.intersects(rect) }) ?? screens.first {
            return CaptureGeometry.clampedWindowFrame(rect, visibleFrame: screen.visibleFrame)
        }
        return CGRect(origin: rect.origin, size: imageSize)
    }
}
