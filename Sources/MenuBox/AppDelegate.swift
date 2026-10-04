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
            guard (try? MenuBoxTerms.agreement().allowsAppUse) == true else { exit(1) }
            MenuBarAccessDiagnostics.writeLayoutSnapshot()
            return
        }
        if CommandLine.arguments.contains(FullDiskAccessRequest.helperArgument) {
            guard (try? MenuBoxTerms.agreement().allowsAppUse) == true else { exit(1) }
            exit(FullDiskAccessRequest.runHelper())
        }
        if CommandLine.arguments.contains("--menubox-visibility-recovery") {
            exit(NativeMenuBarRecovery.runHelper())
        }
        if CommandLine.arguments.contains("--menubox-settings-preview") {
            MenuBoxSettingsPreview.run()
            return
        }
        if CommandLine.arguments.contains("--menubox-onboarding-preview") {
            MenuBoxOnboardingPreview.run()
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
    private var launchGate: MenuBoxLaunchGate?
    lazy var lifecycle = AppLifecycleController(
        mode: .accessory,
        reopen: .custom { [weak self] _ in self?.reopen() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recovery only restores previous system state; it does not enable app features.
        do { try NativeMenuBarPlacement.restore() }
        catch { NSLog("[MenuBox] Menu bar position recovery pending: %@", error.localizedDescription) }
        do { try NativeMenuBarRecovery.restore() }
        catch { NSLog("[MenuBox] Menu bar recovery pending: %@", error.localizedDescription) }
        prepareLaunch()
    }

    private func prepareLaunch() {
        do {
            let agreement = try MenuBoxTerms.agreement()
            launchGate = MenuBoxLaunchGate(agreement: agreement)
            do { try diagnostics.prepare() }
            catch { NSLog("[MenuBox] Crash reporting configuration unavailable: %@", error.localizedDescription) }
            controller = MenuBoxController(updates: updates.settings, agreement: agreement,
                crashPreference: diagnostics.settingsPreference,
                onReady: { [weak self] in self?.startAcceptedApp() })
            controller?.prepareForLaunch()
        } catch {
            // Missing legal resources must not silently bypass the launch gate.
            let alert = NSAlert()
            alert.messageText = menuBoxLocalized("The bundled terms could not be loaded.")
            alert.informativeText = menuBoxLocalized("Retry loading the terms or quit MenuBox. App features have not started.")
            alert.addButton(withTitle: menuBoxLocalized("Retry"))
            alert.addButton(withTitle: menuBoxLocalized("Quit MenuBox"))
            if alert.runModal() == .alertFirstButtonReturn { prepareLaunch() }
            else { NSApp.terminate(nil) }
        }
    }

    private func startAcceptedApp() {
        launchGate?.startIfAllowed { [self] in
            do { try diagnostics.start() }
            catch { NSLog("[MenuBox] Crash reporting could not start: %@", String(describing: error)) }
            do { try updates.start() }
            catch { NSLog("[MenuBox] Updater unavailable: %@", error.localizedDescription) }
            controller?.start()
            if UserDefaults.standard.bool(forKey: "MenuBoxEnableVisibilityAccessProbe") {
                MenuBarAccessDiagnostics.writeSnapshot()
                MenuBarAccessDiagnostics.writeLayoutSnapshot()
            }
            MenuBarVisibilityRoundTripProbe.runIfRequested()
        }
    }

    private func reopen() {
        if let controller { controller.reopen() }
        else { prepareLaunch() }
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
