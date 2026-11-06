import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noScreens
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "PinShot 没有「屏幕录制」权限，无法截图。"
        case .noScreens:
            return "没有检测到可用的显示器。"
        case .captureFailed(let reason):
            return reason
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 PinShot，然后重新启动应用。"
        case .noScreens:
            return nil
        case .captureFailed:
            return "如果刚刚授予权限，请退出并重新打开 PinShot 后再试。"
        }
    }
}

/// 抓取所有屏幕的原生分辨率截图。
@MainActor
final class ScreenCapturer {

    // MARK: - 权限

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗；已授权时直接返回 true
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// 清除本 App 的屏幕录制授权记录（用于 ad-hoc 重建后旧授权条目失效的情况）。
    /// 之后需要退出并重开应用，让系统重新弹授权。
    @discardableResult
    static func resetScreenRecordingPermission() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            NSLog("[PinShot] tccutil reset ScreenCapture \(bundleID) status=\(process.terminationStatus)")
            return process.terminationStatus == 0
        } catch {
            NSLog("[PinShot] tccutil 执行失败: \(error.localizedDescription)")
            return false
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 抓屏

    /// 真实探测一次屏幕捕获能力。用于「重新检查」：
    /// 预检 CGPreflightScreenCaptureAccess 在授权后可能仍然返回 false（进程级缓存），
    /// 但 ScreenCaptureKit 可能已经可用，因此以一次真实截图为最终判据。
    static func probeCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 64
            configuration.height = 64
            configuration.showsCursor = false
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return true
        } catch {
            NSLog("[PinShot] probe capture permission failed: \(error.localizedDescription)")
            return false
        }
    }

    func captureAllScreens() async -> Result<[ScreenSnapshot], ScreenCaptureError> {
        // 不在这里用 CGPreflight 直接短路：预检缓存可能滞后，先真实抓一次再判断。

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return .failure(.noScreens) }

        // 先把 SCShareableContent 里的 SCDisplay 和 NSScreen 对上号
        var displaysByID: [CGDirectDisplayID: SCDisplay] = [:]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for display in content.displays {
                displaysByID[display.displayID] = display
            }
        } catch {
            NSLog("[PinShot] SCShareableContent failed: \(error.localizedDescription)")
        }

        var snapshots: [ScreenSnapshot] = []
        for screen in screens {
            guard let displayID = Self.displayID(of: screen) else { continue }
            let scale = screen.backingScaleFactor

            var image: CGImage?
            if let display = displaysByID[displayID] {
                image = await Self.capture(display: display)
            }
            if image == nil {
                image = Self.captureWithCLI(screen: screen)
            }
            guard let cgImage = image else {
                NSLog("[PinShot] capture failed for display \(displayID)")
                continue
            }
            // 用实际像素/点推出 scale：兜底路径可能拿到 1x 截图，不能盲信 backingScaleFactor
            let effectiveScale = screen.frame.width > 0
                ? CGFloat(cgImage.width) / screen.frame.width
                : scale
            snapshots.append(
                ScreenSnapshot(displayID: displayID, frame: screen.frame, scale: effectiveScale, image: cgImage)
            )
        }

        if snapshots.isEmpty {
            if !Self.hasScreenRecordingPermission() {
                return .failure(.permissionDenied)
            }
            return .failure(.captureFailed("无法获取屏幕画面。请确认已授予「屏幕录制」权限，并重新启动 PinShot。"))
        }
        return .success(snapshots)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - ScreenCaptureKit

    @available(macOS 14.0, *)
    private static func capture(display: SCDisplay) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // SCDisplay.width/height 在部分系统/配置下是「点」，直接用会得到 1x 截图；
        // 用 filter.contentRect × pointPixelScale 得到真正的原生像素尺寸。
        let pointScale = CGFloat(max(filter.pointPixelScale, 1))
        let pixelWidth = Int((filter.contentRect.width * pointScale).rounded())
        let pixelHeight = Int((filter.contentRect.height * pointScale).rounded())
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            NSLog("[PinShot] SCScreenshotManager failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 兜底：screencapture CLI

    /// 屏幕捕获的兜底路径（极少用到）。-D 使用 1 起始的显示器序号。
    private static func captureWithCLI(screen: NSScreen) -> CGImage? {
        guard let index = NSScreen.screens.firstIndex(of: screen) else { return nil }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", String(index + 1), "-t", "png", tmpURL.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return Self.loadPNG(url: tmpURL)
    }

    static func loadPNG(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
