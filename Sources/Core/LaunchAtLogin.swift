import Darwin
import Foundation
import ServiceManagement

/// 开机启动（登录项）。
///
/// 优先使用 macOS 13+ 的 `SMAppService.mainApp`。本机是 ad-hoc 签名、开发期应用也不在
/// `/Applications` 里，系统通常会拒绝注册；此时回退到
/// `~/Library/LaunchAgents/com.kuxin.pinshot.login.plist` + `launchctl bootstrap/bootout`。
///
/// 所有失败路径只写日志并返回 false，不抛异常、不崩溃，供设置界面回滚开关。
enum LaunchAtLogin {

    /// 回退 LaunchAgent 的 Label / 文件名
    static let agentLabel = "com.kuxin.pinshot.login"

    /// `~/Library/LaunchAgents/<label>.plist`
    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// 当前进程是否运行在 .app bundle 中（用 `swift script.swift` 跑时是 false）
    static var isRunningInAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// 当前应用可执行文件路径，写进 LaunchAgent 的 ProgramArguments
    static var appExecutablePath: String {
        if let url = Bundle.main.executableURL { return url.path }
        return Bundle.main.bundlePath + "/Contents/MacOS/\(PinShotConstants.appName)"
    }

    /// 当前是否已开启开机启动（SMAppService 已启用，或回退 LaunchAgent 已存在且指向当前 App）。
    static var isEnabled: Bool {
        if isRunningInAppBundle, SMAppService.mainApp.status == .enabled { return true }
        return isLegacyAgentInstalled
    }

    /// 开启 / 关闭开机启动，返回是否达到期望状态。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            if enableViaSMAppService() {
                // SMAppService 生效后清掉可能残留的回退项，避免重复启动
                removeLegacyAgent()
                return isEnabled
            }
            return installLegacyAgent()
        } else {
            disableViaSMAppService()
            removeLegacyAgent()
            return !isEnabled
        }
    }

    // MARK: - SMAppService（macOS 13+）

    private static func enableViaSMAppService() -> Bool {
        guard isRunningInAppBundle else { return false }
        let service = SMAppService.mainApp
        if service.status == .enabled { return true }
        do {
            try service.register()
        } catch {
            NSLog("[PinShot] SMAppService.register 失败（将回退 LaunchAgent）: \(error.localizedDescription)")
            return false
        }
        guard service.status == .enabled else {
            // 有的系统会把注册结果置为「等待用户批准」，此时登录项还不会生效；
            // 撤回并回退 LaunchAgent，确保「登录时自动启动」真的是开着的状态。
            NSLog("[PinShot] SMAppService 状态为 \(service.status.rawValue)，回退 LaunchAgent")
            try? service.unregister()
            return false
        }
        return true
    }

    private static func disableViaSMAppService() {
        guard isRunningInAppBundle else { return }
        let service = SMAppService.mainApp
        guard service.status != .notRegistered else { return }
        do {
            try service.unregister()
        } catch {
            NSLog("[PinShot] SMAppService.unregister 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 回退：LaunchAgent

    private static var guiDomain: String { "gui/\(getuid())" }

    private static var isLegacyAgentInstalled: Bool {
        guard let data = try? Data(contentsOf: agentPlistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let executable = arguments.first
        else { return false }
        return executable == appExecutablePath
    }

    /// 写入 plist 并尝试 bootstrap（bootstrap 只影响本次会话的立即加载；
    /// 下次登录时系统会自动读取 ~/Library/LaunchAgents，所以文件存在即视为开启成功）。
    private static func installLegacyAgent() -> Bool {
        let plistURL = agentPlistURL
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[PinShot] 无法创建 LaunchAgents 目录: \(error.localizedDescription)")
            return false
        }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [appExecutablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            NSLog("[PinShot] 写入 LaunchAgent 失败: \(error.localizedDescription)")
            return false
        }

        // 先卸载旧服务再加载最新的 plist（服务已加载时 bootstrap 会失败）
        _ = runLaunchctl(["bootout", guiDomain, plistURL.path])
        if !runLaunchctl(["bootstrap", guiDomain, plistURL.path]) {
            NSLog("[PinShot] launchctl bootstrap 失败；plist 已写入，下次登录仍会生效")
        }
        return isLegacyAgentInstalled
    }

    private static func removeLegacyAgent() {
        let plistURL = agentPlistURL
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = runLaunchctl(["bootout", guiDomain, plistURL.path])
        }
        try? FileManager.default.removeItem(at: plistURL)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            NSLog("[PinShot] 无法删除 LaunchAgent: \(plistURL.path)")
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[PinShot] launchctl 执行失败: \(error.localizedDescription)")
            return false
        }
    }
}
