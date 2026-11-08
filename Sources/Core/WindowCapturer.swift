import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 捕获当前前台窗口（Shottr 风格「窗口截图」的轻量实现）。
enum WindowCaptureError: LocalizedError {
    case noWindow
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindow: return "没有找到可捕获的窗口。"
        case .captureFailed(let reason): return "窗口截图失败：\(reason)"
        }
    }
}

@MainActor
enum WindowCapturer {

    /// 返回窗口截图和屏幕上的窗口 frame（Cocoa 全局坐标，可能不准确，仅用于初始放置参考）。
    static func captureFrontmostWindow() async throws -> (image: PinnedImage, frame: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // 按窗口服务器 Z 序从前往后，找到第一个符合条件的普通窗口。
        let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let orderedIDs: [CGWindowID] = infoList.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            guard window.isOnScreen, window.windowLayer == 0 else { return false }
            guard window.frame.width >= 80, window.frame.height >= 60 else { return false }
            guard let app = window.owningApplication else { return false }
            guard app.processID != ownPID else { return false }
            return true
        }

        var chosen: SCWindow?
        for id in orderedIDs {
            if let match = candidates.first(where: { $0.windowID == id }) {
                chosen = match
                break
            }
        }
        guard let window = chosen else { throw WindowCaptureError.noWindow }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let pointSize = window.frame.size
            return (PinnedImage(cgImage: image, pointSize: pointSize), window.frame)
        } catch {
            throw WindowCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
