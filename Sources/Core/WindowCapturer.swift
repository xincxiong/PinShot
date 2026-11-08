import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 捕获当前前台窗口或用户选择的窗口（Shottr 风格「窗口截图」）。
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

/// 窗口选择器中的一项（持有 SCWindow 以便选择后直接捕获）。
struct WindowCandidate {
    let windowID: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let frame: CGRect
    fileprivate let window: SCWindow
}

@MainActor
enum WindowCapturer {

    /// 按窗口服务器 Z 序从前往后列出可捕获的普通窗口。
    static func listWindows() async -> [WindowCandidate] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            let orderedIDs: [CGWindowID] = infoList.compactMap {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier

            var candidates: [WindowCandidate] = []
            for id in orderedIDs {
                guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                guard window.isOnScreen, window.windowLayer == 0 else { continue }
                guard window.frame.width >= 80, window.frame.height >= 60 else { continue }
                guard let app = window.owningApplication, app.processID != ownPID else { continue }
                let appName = app.applicationName.isEmpty ? "窗口" : app.applicationName
                let rawTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? "未命名窗口" : rawTitle
                let icon = NSRunningApplication(processIdentifier: app.processID)?.icon
                candidates.append(WindowCandidate(
                    windowID: window.windowID,
                    title: title,
                    appName: appName,
                    icon: icon,
                    frame: window.frame,
                    window: window
                ))
                if candidates.count >= 18 { break }
            }
            return candidates
        } catch {
            NSLog("[PinShot] listWindows failed: \(error.localizedDescription)")
            return []
        }
    }

    /// 捕获指定候选窗口；返回的 frame 为 SCWindow 的全局坐标（仅作初始放置参考）。
    static func capture(_ candidate: WindowCandidate) async throws -> (image: PinnedImage, frame: CGRect) {
        let filter = SCContentFilter(desktopIndependentWindow: candidate.window)
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
            return (PinnedImage(cgImage: image, pointSize: candidate.frame.size), candidate.frame)
        } catch {
            throw WindowCaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// 不选择窗口时抓取当前前台窗口（保留旧入口，供菜单/调试使用）。
    static func captureFrontmostWindow() async throws -> (image: PinnedImage, frame: CGRect) {
        guard let candidate = await listWindows().first else {
            throw WindowCaptureError.noWindow
        }
        return try await capture(candidate)
    }
}
