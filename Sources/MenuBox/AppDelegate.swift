import AppKit
import Sparkle

@main
enum MenuBoxApplication {
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains(FullDiskAccessRequest.helperArgument) {
            exit(FullDiskAccessRequest.runHelper())
        }
        if CommandLine.arguments.contains("--menubox-visibility-recovery") {
            exit(NativeMenuBarRecovery.runHelper())
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBoxController?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try NativeMenuBarRecovery.restore() }
        catch { NSLog("[MenuBox] Menu bar recovery pending: %@", error.localizedDescription) }
        if UserDefaults.standard.bool(forKey: "MenuBoxEnableVisibilityAccessProbe") {
            MenuBarAccessDiagnostics.writeSnapshot()
        }
        let controller = MenuBoxController(checkForUpdates: { [updaterController] in
            updaterController.checkForUpdates(nil)
        })
        self.controller = controller
        controller.start()
        MenuBarVisibilityRoundTripProbe.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarVisibilityRoundTripProbe.restorePending()
        controller?.stop()
    }
}
