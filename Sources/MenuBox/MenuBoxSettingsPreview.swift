// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore
import MacAppMainMenu
import MacAppLifecycle
import MacAppSettings
import MacAppOnboarding

/// Isolated UI verification: no status items, hotkeys, permission requests,
/// login registration, visibility recovery or updater startup.
@MainActor
final class MenuBoxSettingsPreview: NSObject, NSApplicationDelegate {
    private var mainMenu: MainMenuController?
    private var settings: SettingsWindowController?
    private var onboarding: MenuBoxOnboarding?
    private let suiteName = "MenuBox.SettingsPreview." + UUID().uuidString
    private lazy var lifecycle = AppLifecycleController(mode: .accessory,
        reopen: .custom { [weak self] _ in self?.settings?.show() })

    static func run() {
        let app = NSApplication.shared
        let delegate = MenuBoxSettingsPreview()
        app.delegate = delegate
        do { try delegate.lifecycle.start() }
        catch { NSLog("Settings preview failed: %@", error.localizedDescription); return }
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        let permissions = PermissionStore(defaults: defaults, probe: {
            .init(accessibility: false, fullDiskAccess: .unavailable)
        })
        let model = PermissionSettingsModel([
            .init(id: "accessibility", title: menuBoxLocalized("Accessibility"),
                  detail: menuBoxLocalized("Required to find menu bar icons and open their menus from Box UI. On macOS 27 this permission is called Device Control and Data Access."),
                  readStatus: { .notGranted }, request: {}, openSystemSettings: {}),
            .init(id: "fullDiskAccess", title: menuBoxLocalized("Full Disk Access"),
                  detail: menuBoxLocalized("Required to hide icons on macOS 27. MenuBox accesses protected menu bar settings. This permission also allows access to other apps’ data. Add MenuBox from Applications with the + button if it is missing."),
                  readStatus: { .unknown }, request: {}, openSystemSettings: {})
        ])
        let crashPreference = CrashReportingPreference(activeEnabled: false, save: { _ in })
        settings = SettingsWindowController(store: store, permissions: permissions,
            updates: UpdateSettingsModel(),
            actions: .init(showHiddenIcons: {}, hideHiddenIcons: {}, setShortcutRecordingActive: { _ in },
                writeShortcut: { target, value in
                    store.update {
                        if target == .menuBarIcon { $0.menuBarIconShortcut = value }
                        else { $0.boxUIShortcut = value }
                    }
                }), login: LaunchAtLoginModel(read: { .disabled }, write: { _ in }, openSettings: {}),
            permissionModel: model, language: AppLanguageSettings(save: { _ in }),
            crashPreference: crashPreference,
            showOnboarding: { [weak self] in self?.onboarding?.showIfNeeded(replay: true) })
        guard let document = try? MenuBoxTerms.agreementDocument(preview: true) else { NSApp.terminate(nil); return }
        let receipt = TermsAcceptance(document: document, acceptedAt: Date())
        let agreement = TermsAgreementModel(document: document, store: .init(read: { receipt }, write: { _ in }))
        onboarding = MenuBoxOnboarding(permissions: model, agreement: agreement,
            crashPreference: crashPreference, defaults: defaults)
        settings?.host.window?.setFrameAutosaveName("")
        mainMenu = try? MainMenuController(configuration: .init(appName: "MenuBox",
            settings: { [weak self] in self?.settings?.show() },
            about: { [weak self] in self?.settings?.show(tab: .about) },
            help: { [weak self] in self?.settings?.show(tab: .support) }))
        mainMenu?.install()
        let arguments = CommandLine.arguments
        if arguments.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let pages: [String: SettingsTab] = ["general": .general, "features": .features, "display": .features,
            "shortcuts": .shortcuts, "permissions": .permissions, "updates": .updates,
            "support": .support, "terms": .terms, "about": .about]
        let page = arguments.firstIndex(of: "--preview-page").flatMap { index in
            index + 1 < arguments.count ? pages[arguments[index + 1]] : nil
        }
        settings?.show(tab: page)
        if arguments.contains("--preview-compact"), let window = settings?.host.window {
            window.setContentSize(window.contentMinSize)
        }
        if arguments.contains("--preview-smoke") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let settings, let window = settings.host.window else { exit(1) }
                for page in [SettingsTab.general, .features, .shortcuts, .permissions, .updates, .support, .about] {
                    settings.show(tab: page)
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard window.isVisible, lifecycle.hasExpectedActivationPolicy else { exit(1) }
                    if case .features = page, settings.navigation.pageID != .custom("features") { exit(1) }
                    if case .support = page, settings.navigation.pageID != .support { exit(1) }
                }
                // Legacy terms destinations now resolve to the one support page.
                settings.show(tab: .terms)
                guard settings.navigation.pageID == SupportLegalLinks.settingsPageID else { exit(1) }
                guard !settings.navigation.select(.custom("terms")) else { exit(1) }
                window.miniaturize(nil)
                settings.show()
                guard !window.isMiniaturized else { exit(1) }
                window.close()
                _ = lifecycle.handleReopen(hasVisibleWindows: false)
                guard window.isVisible, lifecycle.hasExpectedActivationPolicy else { exit(1) }
                print("MenuBox settings smoke passed: seven pages, terms redirects to support, minimize, close/reopen, accessory policy")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        lifecycle.handleReopen(hasVisibleWindows: flag)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
