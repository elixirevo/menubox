import AppKit
import Combine
import Foundation

final class SettingsStore: ObservableObject {
    @Published private(set) var settings: AppSettings

    private let defaults: UserDefaults
    private let key = "MenuBox.AppSettings.v3"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacySettings(in: defaults)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            var normalized = decoded
            Self.normalize(&normalized)
            self.settings = normalized
        } else {
            var defaults = AppSettings.defaults
            Self.normalize(&defaults)
            self.settings = defaults
        }
        refreshDisplays()
    }

    private static func migrateLegacySettings(in defaults: UserDefaults) {
        guard defaults.object(forKey: "MenuBox.AppSettings.v3") == nil else { return }

        // Keep the former identifiers only to import settings from existing installations.
        let legacyDomain = defaults === UserDefaults.standard
            ? defaults.persistentDomain(forName: "com.elixirevo.StatusBox") ?? [:]
            : [:]
        var keys = ["StatusBox.AppSettings.v3": "MenuBox.AppSettings.v3"]
        for item in ["main", "tape"] {
            for property in ["Preferred Position", "Visible"] {
                keys["NSStatusItem \(property) com.elixirevo.StatusBox.\(item)"] =
                    "NSStatusItem \(property) com.elixirevo.MenuBox.\(item)"
            }
        }
        for (oldKey, newKey) in keys where defaults.object(forKey: newKey) == nil {
            if let value = defaults.object(forKey: oldKey) ?? legacyDomain[oldKey] {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        Self.normalize(&copy)
        settings = copy
        persist(copy)
    }

    func resetToDefaults() {
        var defaults = AppSettings.defaults
        Self.normalize(&defaults)
        settings = defaults
        persist(defaults)
    }

    func refreshDisplays() {
        update { settings in
            settings.defaultDisplayMode = .menuBar
            settings.displayPolicies = [:]
        }
    }

    func policy(for screen: NSScreen) -> DisplayPolicy {
        DisplayPolicy(
            displayId: screen.menuBoxDisplayId,
            displayName: screen.localizedName,
            mode: .menuBar,
            lastSeenAt: Date()
        )
    }

    func range(for screen: NSScreen) -> HiddenRange? {
        settings.hiddenRanges[screen.menuBoxDisplayId]
    }

    var hasAnyRange: Bool {
        !settings.hiddenRanges.isEmpty
    }

    func setPolicy(displayId: String, mode: DisplayMode) {
        update { settings in
            var policy = settings.displayPolicies[displayId] ?? DisplayPolicy(
                displayId: displayId,
                displayName: displayId,
                mode: mode,
                lastSeenAt: Date()
            )
            policy.mode = mode
            settings.displayPolicies[displayId] = policy
        }
    }

    func setRange(_ range: HiddenRange) {
        update { settings in
            settings.hiddenRanges[range.displayId] = range.normalized
        }
    }

    func removeRange(displayId: String) {
        update { settings in
            settings.hiddenRanges.removeValue(forKey: displayId)
        }
    }

    private func persist(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }

    private static func normalize(_ settings: inout AppSettings) {
        settings.boxMaxColumns = max(1, min(20, settings.boxMaxColumns))

        if !BoxIconAction.clickActionCases.contains(settings.boxIconLeftClickAction) {
            settings.boxIconLeftClickAction = .toggleHiddenIcons
        }
        if !BoxIconAction.clickActionCases.contains(settings.boxIconRightClickAction) {
            settings.boxIconRightClickAction = .showBoxUI
        }

        normalizeShortcut(&settings.menuBarIconShortcut, fallback: .defaultMenuBarIcon)
        normalizeShortcut(&settings.boxUIShortcut, fallback: .defaultBoxUI)
    }

    private static func normalizeShortcut(
        _ shortcut: inout KeyboardShortcutSetting,
        fallback: KeyboardShortcutSetting
    ) {
        if shortcut.key.isEmpty || shortcut.keyCode > 127 || shortcut.modifiers.isEmpty {
            shortcut = fallback
        }
    }
}
