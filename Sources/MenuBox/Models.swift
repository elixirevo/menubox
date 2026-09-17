import AppKit
import Foundation

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case menuBar
    case box
    case disabled

    var id: String { rawValue }

    static let enabledCases: [DisplayMode] = [.menuBar, .disabled]

    var title: String {
        switch self {
        case .menuBar:
            return "Show in menu bar"
        case .box:
            return "Show in Box UI"
        case .disabled:
            return "Do not show on this display"
        }
    }
}

enum BoxIconAction: String, Codable, CaseIterable, Identifiable {
    case toggleHiddenIcons
    case showBoxUI
    case showHiddenIcons
    case hideHiddenIcons
    case openSettings
    case none

    var id: String { rawValue }

    static let clickActionCases: [BoxIconAction] = [
        .toggleHiddenIcons,
        .showBoxUI,
        .openSettings,
        .none
    ]

    var title: String {
        switch self {
        case .toggleHiddenIcons:
            return "Toggle hidden icons"
        case .showBoxUI:
            return "Show Box UI"
        case .showHiddenIcons:
            return "Show hidden icons"
        case .hideHiddenIcons:
            return "Hide hidden icons"
        case .openSettings:
            return "Open Settings"
        case .none:
            return "No action"
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventModifierFlags flags: NSEvent.ModifierFlags) {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }

    var displayTitle: String {
        var title = ""
        if contains(.control) { title += "⌃" }
        if contains(.option) { title += "⌥" }
        if contains(.shift) { title += "⇧" }
        if contains(.command) { title += "⌘" }
        return title
    }
}

struct KeyboardShortcutSetting: Codable, Equatable, Hashable {
    var key: String
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    static let defaultMenuBarIcon = KeyboardShortcutSetting(
        key: "B",
        keyCode: 11,
        modifiers: .option
    )

    static let defaultBoxUI = KeyboardShortcutSetting(
        key: "B",
        keyCode: 11,
        modifiers: .command
    )

    var displayTitle: String {
        "\(modifiers.displayTitle)\(key.uppercased())"
    }

    static func from(event: NSEvent) -> KeyboardShortcutSetting? {
        let modifiers = ShortcutModifiers(eventModifierFlags: event.modifierFlags)
        guard !modifiers.isEmpty else { return nil }
        guard let key = displayKey(for: event) else { return nil }

        return KeyboardShortcutSetting(
            key: key,
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
    }

    private static func displayKey(for event: NSEvent) -> String? {
        if let specialKey = specialKeyTitles[UInt32(event.keyCode)] {
            return specialKey
        }

        guard let character = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !character.isEmpty else {
            return nil
        }
        return character.uppercased()
    }

    private static let specialKeyTitles: [UInt32: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        71: "Clear",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        109: "F10",
        111: "F12",
        118: "F4",
        120: "F2",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑"
    ]
}

struct HiddenRange: Codable, Equatable {
    var displayId: String
    var leftX: CGFloat
    var rightX: CGFloat
    var updatedAt: Date

    var normalized: HiddenRange {
        HiddenRange(
            displayId: displayId,
            leftX: min(leftX, rightX),
            rightX: max(leftX, rightX),
            updatedAt: updatedAt
        )
    }
}

struct DisplayPolicy: Codable, Equatable, Identifiable {
    var displayId: String
    var displayName: String
    var mode: DisplayMode
    var lastSeenAt: Date

    var id: String { displayId }
}

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool
    var defaultDisplayMode: DisplayMode
    var autoHideEnabled: Bool
    var autoHideDelaySeconds: Double
    var boxIconSize: Double
    var boxMaxRows: Int
    var boxMaxColumns: Int
    var boxUIEnabled: Bool
    var boxStatusMessagesEnabled: Bool
    var shortcutsEnabled: Bool
    var boxIconLeftClickAction: BoxIconAction
    var boxIconRightClickAction: BoxIconAction
    var menuBarIconShortcut: KeyboardShortcutSetting
    var boxUIShortcut: KeyboardShortcutSetting
    var calibrationModeEnabled: Bool
    var boxFeatureEnabled: Bool
    var displayPolicies: [String: DisplayPolicy]
    var hiddenRanges: [String: HiddenRange]

    static let defaults = AppSettings(
        launchAtLogin: false,
        defaultDisplayMode: .menuBar,
        autoHideEnabled: true,
        autoHideDelaySeconds: 5,
        boxIconSize: 22,
        boxMaxRows: 2,
        boxMaxColumns: 10,
        boxUIEnabled: true,
        boxStatusMessagesEnabled: false,
        shortcutsEnabled: true,
        boxIconLeftClickAction: .toggleHiddenIcons,
        boxIconRightClickAction: .showBoxUI,
        menuBarIconShortcut: .defaultMenuBarIcon,
        boxUIShortcut: .defaultBoxUI,
        calibrationModeEnabled: false,
        boxFeatureEnabled: false,
        displayPolicies: [:],
        hiddenRanges: [:]
    )

    init(
        launchAtLogin: Bool,
        defaultDisplayMode: DisplayMode,
        autoHideEnabled: Bool,
        autoHideDelaySeconds: Double,
        boxIconSize: Double,
        boxMaxRows: Int,
        boxMaxColumns: Int,
        boxUIEnabled: Bool,
        boxStatusMessagesEnabled: Bool,
        shortcutsEnabled: Bool,
        boxIconLeftClickAction: BoxIconAction,
        boxIconRightClickAction: BoxIconAction,
        menuBarIconShortcut: KeyboardShortcutSetting,
        boxUIShortcut: KeyboardShortcutSetting,
        calibrationModeEnabled: Bool,
        boxFeatureEnabled: Bool,
        displayPolicies: [String: DisplayPolicy],
        hiddenRanges: [String: HiddenRange]
    ) {
        self.launchAtLogin = launchAtLogin
        self.defaultDisplayMode = defaultDisplayMode
        self.autoHideEnabled = autoHideEnabled
        self.autoHideDelaySeconds = autoHideDelaySeconds
        self.boxIconSize = boxIconSize
        self.boxMaxRows = boxMaxRows
        self.boxMaxColumns = boxMaxColumns
        self.boxUIEnabled = boxUIEnabled
        self.boxStatusMessagesEnabled = boxStatusMessagesEnabled
        self.shortcutsEnabled = shortcutsEnabled
        self.boxIconLeftClickAction = boxIconLeftClickAction
        self.boxIconRightClickAction = boxIconRightClickAction
        self.menuBarIconShortcut = menuBarIconShortcut
        self.boxUIShortcut = boxUIShortcut
        self.calibrationModeEnabled = calibrationModeEnabled
        self.boxFeatureEnabled = boxFeatureEnabled
        self.displayPolicies = displayPolicies
        self.hiddenRanges = hiddenRanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        defaultDisplayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .defaultDisplayMode) ?? .menuBar
        autoHideEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoHideEnabled) ?? true
        autoHideDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .autoHideDelaySeconds) ?? 5
        boxIconSize = try container.decodeIfPresent(Double.self, forKey: .boxIconSize) ?? 22
        boxMaxRows = try container.decodeIfPresent(Int.self, forKey: .boxMaxRows) ?? 2
        boxMaxColumns = try container.decodeIfPresent(Int.self, forKey: .boxMaxColumns) ?? 10
        boxUIEnabled = try container.decodeIfPresent(Bool.self, forKey: .boxUIEnabled) ?? true
        boxStatusMessagesEnabled = try container.decodeIfPresent(Bool.self, forKey: .boxStatusMessagesEnabled) ?? false
        shortcutsEnabled = try container.decodeIfPresent(Bool.self, forKey: .shortcutsEnabled) ?? true
        boxIconLeftClickAction = try container.decodeIfPresent(BoxIconAction.self, forKey: .boxIconLeftClickAction) ?? .toggleHiddenIcons
        boxIconRightClickAction = try container.decodeIfPresent(BoxIconAction.self, forKey: .boxIconRightClickAction) ?? .showBoxUI
        menuBarIconShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .menuBarIconShortcut) ?? .defaultMenuBarIcon
        boxUIShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .boxUIShortcut) ?? .defaultBoxUI
        calibrationModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .calibrationModeEnabled) ?? false
        boxFeatureEnabled = try container.decodeIfPresent(Bool.self, forKey: .boxFeatureEnabled) ?? false
        displayPolicies = try container.decodeIfPresent([String: DisplayPolicy].self, forKey: .displayPolicies) ?? [:]
        hiddenRanges = try container.decodeIfPresent([String: HiddenRange].self, forKey: .hiddenRanges) ?? [:]
    }
}

extension NSScreen {
    var menuBoxDisplayId: String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return localizedName
    }
}
