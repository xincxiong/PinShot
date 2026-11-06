import AppKit

@main
enum PinShotMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        // --render-test <outdir>：离屏渲染自检（不依赖屏幕录制权限）
        if let renderIndex = arguments.firstIndex(of: "--render-test") {
            let outputDirectory: String
            if renderIndex + 1 < arguments.count, !arguments[renderIndex + 1].hasPrefix("-") {
                outputDirectory = arguments[renderIndex + 1]
            } else {
                outputDirectory = FileManager.default.currentDirectoryPath + "/build/render"
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let ok = RenderSelfTest.run(outputDirectory: outputDirectory)
            exit(ok ? 0 : 1)
        } else if let renderIndex = arguments.firstIndex(of: "--render-ui") {
            let outputDirectory: String
            if renderIndex + 1 < arguments.count, !arguments[renderIndex + 1].hasPrefix("-") {
                outputDirectory = arguments[renderIndex + 1]
            } else {
                outputDirectory = FileManager.default.currentDirectoryPath + "/build/ui"
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let ok = UIRenderTest.run(outputDirectory: outputDirectory)
            exit(ok ? 0 : 1)
        } else if arguments.contains("--version") {
            print("\(PinShotConstants.appName) \(PinShotConstants.version)")
            exit(0)
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}
