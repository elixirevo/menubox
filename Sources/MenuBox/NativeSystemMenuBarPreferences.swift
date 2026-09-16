import Foundation
import CoreFoundation

/// Per-control settings, not a global menu bar restriction. These values were
/// compared with System Settings on macOS 27; unrelated controls are untouched.
enum NativeSystemMenuBarPreferences {
    enum Setting: String, Codable, CaseIterable {
        case nowPlaying, inputMenu, sound, wifi, battery, focus, screenMirroring, display, timer

        var itemID: String {
            switch self {
            case .nowPlaying: return "com.apple.MenuBarAgent:com.apple.menuextra.now-playing"
            case .inputMenu: return "com.apple.TextInputMenuAgent:0"
            case .sound: return "com.apple.MenuBarAgent:com.apple.menuextra.sound"
            case .wifi: return "com.apple.MenuBarAgent:com.apple.menuextra.wifi"
            case .battery: return "com.apple.MenuBarAgent:com.apple.menuextra.battery"
            case .focus: return "com.apple.MenuBarAgent:com.apple.menuextra.focusmode"
            case .screenMirroring: return "com.apple.MenuBarAgent:com.apple.menuextra.screen-mirroring"
            case .display: return "com.apple.MenuBarAgent:com.apple.menuextra.display"
            case .timer: return "com.apple.MenuBarAgent:com.apple.menuextra.timer"
            }
        }
        var domain: String {
            self == .inputMenu ? "com.apple.TextInputMenu" : "com.apple.controlcenter"
        }
        var key: String {
            switch self {
            case .inputMenu: return "visible"
            case .nowPlaying: return "NowPlaying"
            case .sound: return "Sound"
            case .wifi: return "WiFi"
            case .battery: return "Battery"
            case .focus: return "FocusModes"
            case .screenMirroring: return "ScreenMirroring"
            case .display: return "Display"
            case .timer: return "Timer"
            }
        }
        var host: CFString { self == .inputMenu ? kCFPreferencesAnyHost : kCFPreferencesCurrentHost }
        var hiddenValue: Value { self == .inputMenu ? .boolean(false) : .integer(8) }
    }
    enum Value: Codable, Equatable {
        case boolean(Bool), integer(Int)
        var object: NSNumber {
            switch self {
            case .boolean(let value): return NSNumber(value: value)
            case .integer(let value): return NSNumber(value: value)
            }
        }
    }
    struct Change: Codable, Equatable {
        let setting: Setting
        let original: Value?
    }

    static func validate(_ changes: [Change]) throws {
        guard Set(changes.map(\.setting)).count == changes.count else { throw Failure.schema }
        for change in changes {
            switch (change.setting, change.original) {
            case (_, nil), (.inputMenu, .boolean): break
            case (let setting, .integer(let value)) where setting != .inputMenu && (0...31).contains(value): break
            default: throw Failure.schema
            }
        }
    }
    enum Failure: LocalizedError {
        case unsupported(String), schema, concurrentChange, write
        var errorDescription: String? {
            switch self {
            case .unsupported(let item): return "This macOS control cannot be hidden yet: \(item). Move it to the right of the marker."
            case .schema: return "The macOS control visibility setting has an unsupported format."
            case .concurrentChange: return "A macOS control setting changed during hiding. Please try again."
            case .write: return "macOS did not confirm the control visibility change."
            }
        }
    }

    static func setting(for itemID: String) throws -> Setting {
        guard let setting = Setting.allCases.first(where: { $0.itemID == itemID }) else {
            throw Failure.unsupported(itemID)
        }
        return setting
    }

    static func read(_ setting: Setting) throws -> Value? {
        guard CFPreferencesSynchronize(setting.domain as CFString, kCFPreferencesCurrentUser, setting.host) else {
            throw Failure.write
        }
        guard let object = CFPreferencesCopyValue(setting.key as CFString, setting.domain as CFString,
                                                 kCFPreferencesCurrentUser, setting.host) else { return nil }
        guard let number = object as? NSNumber else { throw Failure.schema }
        let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
        if setting == .inputMenu {
            guard isBoolean else { throw Failure.schema }
            return .boolean(number.boolValue)
        }
        guard !isBoolean, number.doubleValue == Double(number.intValue), (0...31).contains(number.intValue) else {
            throw Failure.schema
        }
        return .integer(number.intValue)
    }

    static func prepare(_ itemIDs: Set<String>) throws -> [Change] {
        try itemIDs.sorted().map { id in
            let setting = try setting(for: id)
            return try Change(setting: setting, original: read(setting))
        }
    }

    static func apply(_ changes: [Change],
                      read: (Setting) throws -> Value? = NativeSystemMenuBarPreferences.read,
                      write: (Value?, Setting) throws -> Void = NativeSystemMenuBarPreferences.write) throws {
        try validate(changes)
        for change in changes {
            guard try read(change.setting) == change.original else { throw Failure.concurrentChange }
            try write(change.setting.hiddenValue, change.setting)
        }
    }

    static func restore(_ changes: [Change],
                        read: (Setting) throws -> Value? = NativeSystemMenuBarPreferences.read,
                        write: (Value?, Setting) throws -> Void = NativeSystemMenuBarPreferences.write) throws {
        try validate(changes)
        for change in changes {
            // A user edit made while hidden takes precedence over our temporary
            // value. Restore only values still owned by this transaction.
            if try read(change.setting) == change.setting.hiddenValue {
                try write(change.original, change.setting)
            }
        }
    }

    static func reapply(_ changes: [Change],
                        read: (Setting) throws -> Value? = NativeSystemMenuBarPreferences.read,
                        write: (Value?, Setting) throws -> Void = NativeSystemMenuBarPreferences.write) throws {
        try validate(changes)
        for change in changes {
            let current = try read(change.setting)
            if current == change.setting.hiddenValue { continue }
            guard current == change.original else { throw Failure.concurrentChange }
            try write(change.setting.hiddenValue, change.setting)
        }
    }

    private static func write(_ value: Value?, _ setting: Setting) throws {
        CFPreferencesSetValue(setting.key as CFString, value?.object, setting.domain as CFString,
                              kCFPreferencesCurrentUser, setting.host)
        guard CFPreferencesSynchronize(setting.domain as CFString, kCFPreferencesCurrentUser, setting.host),
              try read(setting) == value else { throw Failure.write }
    }
}
