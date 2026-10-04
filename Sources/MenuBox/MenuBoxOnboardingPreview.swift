// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppLifecycle
import MacAppOnboarding
import MacAppSettings

/// Runs only with an explicit development flag. No real consent, permissions or services.
@MainActor
final class MenuBoxOnboardingPreview: NSObject, NSApplicationDelegate {
    private var host: OnboardingWindowController?
    private var agreementHost: TermsAgreementWindowController?
    private lazy var lifecycle = AppLifecycleController(mode: .accessory,
        reopen: .custom { [weak self] _ in self?.host?.showIfNeeded(); self?.agreementHost?.showIfNeeded() })
    static func run() {
        let app = NSApplication.shared
        let delegate = MenuBoxOnboardingPreview()
        app.delegate = delegate
        do { try delegate.lifecycle.start() }
        catch { NSLog("Onboarding preview failed: %@", error.localizedDescription); return }
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let permissions = PermissionSettingsModel([
            .init(id: "accessibility", title: menuBoxLocalized("Accessibility"),
                  detail: menuBoxLocalized("Required to find menu bar icons and open their menus from Box UI. On macOS 27 this permission is called Device Control and Data Access."),
                  readStatus: { .notGranted }, request: {}, openSystemSettings: {}),
            .init(id: "fullDiskAccess", title: menuBoxLocalized("Full Disk Access"),
                  detail: menuBoxLocalized("Required to hide icons on macOS 27. MenuBox accesses protected menu bar settings. This permission also allows access to other apps’ data. Add MenuBox from Applications with the + button if it is missing."),
                  readStatus: { .notGranted }, request: {}, openSystemSettings: {})
        ])
        let isSmoke = args.contains("--preview-smoke")
        var dismissed = 0
        var quitRequested = false
        var completed = 0
        do {
            let document = try MenuBoxTerms.agreementDocument(preview: true)
            var receipt: TermsAcceptance?
            let agreement = TermsAgreementModel(document: document,
                store: .init(read: { receipt }, write: { receipt = $0 }))
            if args.contains("--preview-terms-update") {
                agreementHost = TermsAgreementWindowController(
                    identity: SettingsIdentity(bundle: .main, icon: NSApp.applicationIconImage),
                    model: agreement, autosaveName: "", onAccepted: { NSApp.terminate(nil) },
                    onQuit: { NSApp.terminate(nil) })
                agreementHost?.showIfNeeded()
                return
            }
            let model = try MenuBoxOnboarding.makeModel(permissions: permissions, agreement: agreement,
                crashPreference: CrashReportingPreference(activeEnabled: false, save: { _ in }),
                store: .init(readCompletedVersion: { completed }, writeCompletedVersion: { completed = $0 }))
            if let index = args.firstIndex(of: "--preview-step"), index + 1 < args.count,
               let number = Int(args[index + 1]), (1...model.steps.count).contains(number) {
                for _ in 1..<number { guard model.canAdvance else { break }; model.advance() }
            }
            host = OnboardingWindowController(identity: SettingsIdentity(bundle: .main, icon: NSApp.applicationIconImage),
                model: model, autosaveName: "", onFinish: { NSApp.terminate(nil) },
                onDismiss: {
                    dismissed += 1
                    if !isSmoke { NSApp.terminate(nil) }
                }, onQuit: {
                    quitRequested = true
                    if !isSmoke { NSApp.terminate(nil) }
                })
            host?.showIfNeeded()
            if isSmoke {
                Task { @MainActor in
                    guard let window = host?.window else { exit(1) }
                    let step = model.currentIndex
                    window.performClose(nil)
                    guard dismissed == 0, quitRequested, completed == 0, receipt == nil,
                          model.shouldPresent, model.requiresTermsAgreement else { exit(1) }
                    agreement.isAcknowledged = true
                    guard host?.showIfNeeded() == true, model.currentIndex == step else { exit(1) }
                    guard !agreement.isAcknowledged else { exit(1) }
                    window.miniaturize(nil)
                    guard host?.showIfNeeded() == true, !window.isMiniaturized else { exit(1) }
                    // Allow SwiftUI tasks to run, then navigate with every permission denied.
                    for _ in model.steps.indices {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard let window = host?.window, window.isVisible,
                              lifecycle.hasExpectedActivationPolicy else { exit(1) }
                        window.contentView?.layoutSubtreeIfNeeded()
                        if model.currentTermsAgreement != nil, agreement.requiresAcceptance {
                            guard !model.canAdvance, !model.advance(), receipt == nil else { exit(1) }
                            // This is an explicitly labeled, nonbinding in-memory preview only.
                            agreement.isAcknowledged = true
                        }
                        guard model.canAdvance else { exit(1) }
                        if model.advance() { break }
                    }
                    guard completed == MenuBoxOnboarding.flowVersion, !model.shouldPresent,
                          receipt != nil, agreement.allowsAppUse else { exit(1) }
                    print("MenuBox onboarding smoke passed: mandatory explicit terms, quit without acceptance, checkbox reset, minimize, optional permissions/diagnostics, completion and accessory policy")
                    NSApp.terminate(nil)
                }
            }
        } catch { NSLog("Onboarding preview failed: %@", error.localizedDescription); NSApp.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        lifecycle.handleReopen(hasVisibleWindows: flag)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
