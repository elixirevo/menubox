// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import Combine
import MacAppCore
import MacAppSettings
import SwiftUI

func menuBoxLocalized(_ key: String) -> String {
    AppLocalizer.current.string(key, bundle: .module)
}

enum SettingsTab { case general, display, shortcuts, permissions, updates, support, terms, about }
enum MenuBoxShortcutTarget { case menuBarIcon, boxUI }

struct SettingsActions {
    var showHiddenIcons: () -> Void
    var hideHiddenIcons: () -> Void
    var setShortcutRecordingActive: (Bool) -> Void
    var writeShortcut: (MenuBoxShortcutTarget, KeyboardShortcutSetting) throws -> Void
}

enum MenuBoxSettingsError: LocalizedError {
    case unavailable, shortcutRequired, shortcutUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return menuBoxLocalized("Settings are unavailable.")
        case .shortcutRequired: return menuBoxLocalized("Use Enable shortcuts in General to disable shortcuts.")
        case .shortcutUnavailable: return menuBoxLocalized("This shortcut could not be registered. Choose another combination.")
        }
    }
}

extension KeyboardShortcutSetting {
    var settingsShortcut: SettingsShortcut {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return .init(keyCode: UInt16(clamping: keyCode), modifiers: flags, keyLabel: key)
    }

    init(_ shortcut: SettingsShortcut) {
        self.init(key: shortcut.keyLabel, keyCode: UInt32(shortcut.keyCode),
                  modifiers: .init(eventModifierFlags: shortcut.modifierFlags))
    }
}

extension PermissionAccess {
    var settingsStatus: SettingsPermissionStatus {
        switch self {
        case .available: return .granted
        case .denied: return .notGranted
        case .unavailable: return .unknown
        }
    }
}

/// Adapts existing MenuBox storage and services to the shared settings UI.
@MainActor
final class SettingsWindowController {
    let navigation = MacAppSettings.SettingsNavigation()
    let shortcuts: ShortcutSettingsModel
    let permissionModel: PermissionSettingsModel
    let login: LaunchAtLoginModel
    private let store: SettingsStore
    private let permissions: PermissionStore
    private let updates: UpdateSettingsModel
    private let actions: SettingsActions
    private let language: AppLanguageSettings?
    private let crashPreference: CrashReportingPreference?
    private var observations = Set<AnyCancellable>()

    private lazy var identity = SettingsIdentity(bundle: .main, icon: NSApp.applicationIconImage,
        website: URL(string: "https://github.com/elixirevo/menubox"))
    private lazy var support = try! SupportSettingsModel(
        diagnostics: SupportDiagnostics(identity: identity, distribution: .direct),
        links: [
            try! SupportLink(.help, url: URL(string: "https://github.com/elixirevo/menubox#readme")!),
            try! SupportLink(.reportIssue, url: URL(string: "https://github.com/elixirevo/menubox/issues")!)
        ]
    )

    private lazy var reset = try! SettingsResetModel(actions: [
        .init(id: "menubox", title: "MenuBox", detail: menuBoxLocalized(
            "Restore auto-hide, Box UI, click actions, shortcuts and saved ranges. Language, login items, updates and macOS permissions stay unchanged."
        )) { [weak self] in
            guard let self else { return }
            self.shortcuts.stopRecording()
            // Login registration is OS-owned; do not reset its legacy mirror.
            self.store.resetToDefaults(preservingLoginItem: true)
            self.shortcuts.refresh()
        }
    ])

    private lazy var pages = try! SettingsPages([
        .builtIn(.general),
        .custom(id: "display", title: menuBoxLocalized("Display"), symbol: "menubar.rectangle", color: .orange) { [store, actions] in
            MenuBoxDisplaySettings(store: store, actions: actions)
        },
        .builtIn(.shortcuts), .builtIn(.permissions), .builtIn(.updates), .support,
        .builtIn(.about)
    ])

    private(set) lazy var host = MacAppSettings.SettingsWindowController(
        title: menuBoxLocalized("MenuBox Settings"), autosaveName: "com.elixirevo.MenuBox.Settings",
        navigation: navigation, onClose: { [weak self] in self?.shortcuts.stopRecording() }
    ) { [self] in
        AppSettingsView(
            identity: identity,
            navigation: navigation, shortcuts: shortcuts, permissions: permissionModel,
            updates: updates, language: language, launchAtLogin: login, pages: pages,
            distribution: .direct, support: support, reset: reset,
            supportContent: { AnyView(MenuBoxTermsSupportSection()) }
        ) {
            MenuBoxGeneralSettings(store: store)
            if let crashPreference { DiagnosticsSettingsSection(preference: crashPreference) }
        }
    }

    init(store: SettingsStore, permissions: PermissionStore, updates: UpdateSettingsModel,
         actions: SettingsActions, login: LaunchAtLoginModel? = nil,
         permissionModel: PermissionSettingsModel? = nil, language: AppLanguageSettings? = nil,
         crashPreference: CrashReportingPreference? = nil) {
        self.store = store
        self.permissions = permissions
        self.updates = updates
        self.actions = actions
        self.language = language
        self.crashPreference = crashPreference
        self.login = login ?? LaunchAtLoginModel()
        shortcuts = Self.makeShortcuts(store: store, actions: actions)
        self.permissionModel = permissionModel ?? Self.makePermissions(snapshot: permissions.snapshot)
        store.$settings.sink { [weak shortcuts] _ in
            // @Published emits before storage changes; read on the next main turn.
            DispatchQueue.main.async { shortcuts?.refresh() }
        }.store(in: &observations)
        permissions.$snapshot.removeDuplicates().sink { [weak model = self.permissionModel] _ in
            Task { @MainActor in await model?.refresh() }
        }.store(in: &observations)
    }

    func show(tab: SettingsTab? = nil) {
        navigation.configure(pages)
        shortcuts.refresh()
        login.refresh()
        if let tab {
            let page: SettingsPageID
            switch tab {
            case .general: page = .builtIn(.general)
            case .display: page = .custom("display")
            case .shortcuts: page = .builtIn(.shortcuts)
            case .permissions: page = .builtIn(.permissions)
            case .updates: page = .builtIn(.updates)
            case .support: page = .support
            case .terms: page = SupportLegalLinks.settingsPageID
            case .about: page = .builtIn(.about)
            }
            host.show(pageID: page)
        } else { host.show() }
    }

    static func makeShortcuts(store: SettingsStore, actions: SettingsActions) -> ShortcutSettingsModel {
        func action(_ id: String, _ title: String, _ target: MenuBoxShortcutTarget,
                    _ key: KeyPath<AppSettings, KeyboardShortcutSetting>) -> SettingsShortcutAction {
            .init(id: id, title: menuBoxLocalized(title),
                  read: { store.settings[keyPath: key].settingsShortcut },
                  validate: { if $0 == nil { throw MenuBoxSettingsError.shortcutRequired } },
                  write: { value in
                      guard let value else { throw MenuBoxSettingsError.shortcutRequired }
                      try actions.writeShortcut(target, KeyboardShortcutSetting(value))
                  })
        }
        return ShortcutSettingsModel([
            action("menuBarIcon", "Menu bar icon", .menuBarIcon, \.menuBarIconShortcut),
            action("boxUI", "Box UI", .boxUI, \.boxUIShortcut)
        ], recordingChanged: actions.setShortcutRecordingActive)
    }

    static func makePermissions(snapshot: PermissionSnapshot,
                                readDiskAccess: @escaping () -> PermissionAccess = { FullDiskAccessProbe.read() },
                                openDiskSettings: @escaping () -> Void = { ClickForwarder.openFullDiskAccessSettings() }) -> PermissionSettingsModel {
        var items: [SettingsPermission] = [.accessibility(detail: menuBoxLocalized(
            "Required to find menu bar icons and open their menus from Box UI. On macOS 27 this permission is called Device Control and Data Access."
        ))]
        if snapshot.fullDiskAccess != nil {
            items.append(.init(id: "fullDiskAccess", title: menuBoxLocalized("Full Disk Access"),
                detail: menuBoxLocalized("Required to hide icons on macOS 27. MenuBox accesses protected menu bar settings. This permission also allows access to other apps’ data. Add MenuBox from Applications with the + button if it is missing."),
                readStatus: { readDiskAccess().settingsStatus },
                request: { openDiskSettings() }, openSystemSettings: {
                    ClickForwarder.openFullDiskAccessSettings(registerIfNeeded: false)
                }))
        }
        return PermissionSettingsModel(items)
    }
}

private struct MenuBoxGeneralSettings: View {
    @ObservedObject var store: SettingsStore
    private let delays: [Double] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        SettingsSection(menuBoxLocalized("Auto-hide")) {
            SettingsToggle(menuBoxLocalized("Auto-hide again"), isOn: binding(\.autoHideEnabled))
            SettingsPicker(menuBoxLocalized("Auto-hide delay"), selection: binding(\.autoHideDelaySeconds)) {
                ForEach(Array(Set(delays + [store.settings.autoHideDelaySeconds])).sorted(), id: \.self) { seconds in
                    Text(String(format: menuBoxLocalized("%g seconds"), seconds)).tag(seconds)
                }
            }
        }
        SettingsSection(menuBoxLocalized("Box Icon")) {
            SettingsToggle(menuBoxLocalized("Show Box UI"), isOn: binding(\.boxUIEnabled))
            SettingsPicker(menuBoxLocalized("Left click"), selection: binding(\.boxIconLeftClickAction)) { clickOptions }
            SettingsPicker(menuBoxLocalized("Right click"), selection: binding(\.boxIconRightClickAction)) { clickOptions }
        }
        SettingsSection(menuBoxLocalized("Shortcuts")) {
            SettingsToggle(menuBoxLocalized("Enable shortcuts"), isOn: binding(\.shortcutsEnabled))
        }
    }

    private var clickOptions: some View {
        ForEach(BoxIconAction.clickActionCases) { action in Text(menuBoxLocalized(action.title)).tag(action) }
    }
    private func binding<Value>(_ key: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in store.update { $0[keyPath: key] = value } })
    }
}

private struct MenuBoxDisplaySettings: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions
    var body: some View {
        SettingsSection(menuBoxLocalized("Box Icons")) {
            SettingsToggle(menuBoxLocalized("Show Box UI alerts"), isOn: Binding(
                get: { store.settings.boxStatusMessagesEnabled },
                set: { value in store.update { $0.boxStatusMessagesEnabled = value } }
            ))
            SettingsRow(menuBoxLocalized("Icons per row")) {
                Text("\(store.settings.boxMaxColumns)").monospacedDigit()
                Stepper(menuBoxLocalized("Icons per row"), value: Binding(
                    get: { store.settings.boxMaxColumns },
                    set: { value in store.update { $0.boxMaxColumns = value } }
                ), in: 1...20).labelsHidden()
            }
        }
        SettingsSection(menuBoxLocalized("Menu Bar Icons")) {
            SettingsRow(menuBoxLocalized("Hidden icons")) {
                Button(menuBoxLocalized("Show hidden icons"), action: actions.showHiddenIcons)
                Button(menuBoxLocalized("Hide again"), action: actions.hideHiddenIcons)
            }
        }
    }
}
