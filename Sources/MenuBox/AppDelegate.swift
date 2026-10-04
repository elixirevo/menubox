// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppLifecycle
import MacAppUpdatesSparkle

@main
@MainActor
enum MenuBoxApplication {
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--menubox-layout-inspect") {
            MenuBarAccessDiagnostics.writeLayoutSnapshot()
            return
        }
        if CommandLine.arguments.contains(FullDiskAccessRequest.helperArgument) {
            exit(FullDiskAccessRequest.runHelper())
        }
        if CommandLine.arguments.contains("--menubox-visibility-recovery") {
            exit(NativeMenuBarRecovery.runHelper())
        }
        if CommandLine.arguments.contains("--menubox-settings-preview") {
            MenuBoxSettingsPreview.run()
            return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        do { try delegate.lifecycle.start() }
        catch {
            NSLog("[MenuBox] Unable to start: %@", error.localizedDescription)
            return
        }
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBoxController?
    private let updates = SparkleUpdates()
    private let diagnostics = MenuBoxDiagnostics()
    lazy var lifecycle = AppLifecycleController(
        mode: .accessory,
        reopen: .custom { [weak self] _ in self?.controller?.openSettings() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try diagnostics.start() }
        catch { NSLog("[MenuBox] Crash reporting could not start: %@", String(describing: error)) }
        do { try NativeMenuBarPlacement.restore() }
        catch { NSLog("[MenuBox] Menu bar position recovery pending: %@", error.localizedDescription) }
        do { try NativeMenuBarRecovery.restore() }
        catch { NSLog("[MenuBox] Menu bar recovery pending: %@", error.localizedDescription) }
        if UserDefaults.standard.bool(forKey: "MenuBoxEnableVisibilityAccessProbe") {
            MenuBarAccessDiagnostics.writeSnapshot()
            MenuBarAccessDiagnostics.writeLayoutSnapshot()
        }
        do { try updates.start() }
        catch { NSLog("[MenuBox] Updater unavailable: %@", error.localizedDescription) }
        let controller = MenuBoxController(updates: updates.settings, crashPreference: diagnostics.settingsPreference)
        self.controller = controller
        controller.start()
        MenuBarVisibilityRoundTripProbe.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lifecycle.shouldTerminateAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        lifecycle.handleReopen(hasVisibleWindows: flag)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarVisibilityRoundTripProbe.restorePending()
        controller?.stop()
    }
}
