import AppKit
import Foundation

extension Notification.Name {
    /// 任意设置发生变化。userInfo["key"] 为变化的设置名。
    static let pinShotSettingsDidChange = Notification.Name("com.kuxin.pinshot.settingsDidChange")
}

/// 用户设置，UserDefaults 持久化。所有读写都在主线程。
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let prefix = "pinshot."

    // MARK: - 自动隐藏

    var autoHideEnabled: Bool {
        didSet { persist(autoHideEnabled, "autoHideEnabled"); notify("autoHideEnabled") }
    }
    var autoHideDelay: TimeInterval {
        didSet { persist(autoHideDelay, "autoHideDelay"); notify("autoHideDelay") }
    }
    var ghostAlpha: CGFloat {
        didSet { persist(ghostAlpha, "ghostAlpha"); notify("ghostAlpha") }
    }
    var hideEntirely: Bool {
        didSet { persist(hideEntirely, "hideEntirely"); notify("hideEntirely") }
    }
    var clickThroughWhenHidden: Bool {
        didSet { persist(clickThroughWhenHidden, "clickThroughWhenHidden"); notify("clickThroughWhenHidden") }
    }
    /// 全局暂停自动隐藏（不写死设置，作为会话状态保存也方便）
    var autoHidePaused: Bool {
        didSet { persist(autoHidePaused, "autoHidePaused"); notify("autoHidePaused") }
    }

    // MARK: - 外观

    var showPinBorder: Bool {
        didSet { persist(showPinBorder, "showPinBorder"); notify("showPinBorder") }
    }
    var showPinShadow: Bool {
        didSet { persist(showPinShadow, "showPinShadow"); notify("showPinShadow") }
    }
    var defaultPinAlpha: CGFloat {
        didSet { persist(defaultPinAlpha, "defaultPinAlpha"); notify("defaultPinAlpha") }
    }
    /// 新贴图默认放在桌面（窗口下层），而不是浮在所有窗口上方
    var defaultPinDesktop: Bool {
        didSet { persist(defaultPinDesktop, "defaultPinDesktop"); notify("defaultPinDesktop") }
    }

    // MARK: - 快捷键

    var capturePinHotKey: HotKeyCombo {
        didSet { persistHotKey(capturePinHotKey, "capturePinHotKey"); notify("capturePinHotKey") }
    }
    var captureCopyHotKey: HotKeyCombo {
        didSet { persistHotKey(captureCopyHotKey, "captureCopyHotKey"); notify("captureCopyHotKey") }
    }

    // MARK: - 其他

    var hasCompletedOnboarding: Bool {
        didSet { persist(hasCompletedOnboarding, "hasCompletedOnboarding") }
    }

    // MARK: - 初始化 / 读写

    private init() {
        let d = UserDefaults.standard
        autoHideEnabled = d.object(forKey: prefix + "autoHideEnabled") as? Bool ?? true
        autoHideDelay = d.object(forKey: prefix + "autoHideDelay") as? Double ?? 2.0
        ghostAlpha = d.object(forKey: prefix + "ghostAlpha") as? Double ?? 0.12
        hideEntirely = d.object(forKey: prefix + "hideEntirely") as? Bool ?? false
        clickThroughWhenHidden = d.object(forKey: prefix + "clickThroughWhenHidden") as? Bool ?? true
        autoHidePaused = d.object(forKey: prefix + "autoHidePaused") as? Bool ?? false
        showPinBorder = d.object(forKey: prefix + "showPinBorder") as? Bool ?? true
        showPinShadow = d.object(forKey: prefix + "showPinShadow") as? Bool ?? true
        defaultPinAlpha = d.object(forKey: prefix + "defaultPinAlpha") as? Double ?? 1.0
        defaultPinDesktop = d.object(forKey: prefix + "defaultPinDesktop") as? Bool ?? false
        hasCompletedOnboarding = d.object(forKey: prefix + "hasCompletedOnboarding") as? Bool ?? false

        capturePinHotKey = Self.loadHotKey(d, key: prefix + "capturePinHotKey") ?? .defaultCapturePin
        captureCopyHotKey = Self.loadHotKey(d, key: prefix + "captureCopyHotKey") ?? .defaultCaptureCopy
    }

    func resetToDefaults() {
        autoHideEnabled = true
        autoHideDelay = 2.0
        ghostAlpha = 0.12
        hideEntirely = false
        clickThroughWhenHidden = true
        autoHidePaused = false
        showPinBorder = true
        showPinShadow = true
        defaultPinAlpha = 1.0
        defaultPinDesktop = false
        capturePinHotKey = .defaultCapturePin
        captureCopyHotKey = .defaultCaptureCopy
    }

    private func persist(_ value: Any, _ key: String) {
        defaults.set(value, forKey: prefix + key)
    }

    private func persistHotKey(_ combo: HotKeyCombo, _ key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: prefix + key)
        }
    }

    private static func loadHotKey(_ d: UserDefaults, key: String) -> HotKeyCombo? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    private func notify(_ key: String) {
        NotificationCenter.default.post(name: .pinShotSettingsDidChange, object: self, userInfo: ["key": key])
    }
}
