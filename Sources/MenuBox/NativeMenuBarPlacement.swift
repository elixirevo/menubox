import Foundation
import CoreFoundation

/// A macOS 27 menu session can bring one overflowed item beside Box without
/// revealing the section, dragging the pointer or rewriting other positions.
enum NativeMenuBarPlacement {
    static let preferenceKey = "TrailingItemPreferredPositions"
    static let boxKey = "status:com.elixirevo.MenuBox::com.elixirevo.MenuBox.main"
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar", isDirectory: true)
    static let file = container.appendingPathComponent("Library/Preferences/com.apple.MenuBar.plist")
    static let journalURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MenuBox/Placement/pending.plist")

    struct Change: Codable, Equatable {
        var token: UUID
        var key: String
        var original: Double
        var temporary: Double
    }

    enum Failure: LocalizedError {
        case unavailable, ambiguous, changed, pending, write
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Could not read the menu bar layout. Check MenuBox’s Full Disk Access."
            case .ambiguous: return "Could not identify a safe temporary position for this icon."
            case .changed: return "The menu bar layout changed. Try opening the menu again."
            case .pending: return "The previous icon position still needs to be restored."
            case .write: return "macOS did not confirm the icon position change."
            }
        }
    }

    static func decode(_ value: Any?) throws -> [String: Double] {
        guard let dictionary = value as? [String: NSNumber], !dictionary.isEmpty else { throw Failure.unavailable }
        var positions: [String: Double] = [:]
        for (key, value) in dictionary {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= 0 else { throw Failure.unavailable }
            positions[key] = value.doubleValue
        }
        return positions
    }

    static func plan(bundle: String, identifier: String, positions: [String: Double]) throws -> Change {
        guard !bundle.isEmpty, !bundle.hasPrefix("com.apple."), bundle != NativeMenuBarPreferences.ownBundle,
              let box = positions[boxKey], box > 0 else { throw Failure.ambiguous }
        let prefix = "status:\(bundle)::"
        let candidates = positions.keys.filter { $0.hasPrefix(prefix) }
        let exact = prefix + identifier
        let key: String
        if !identifier.isEmpty, candidates.contains(exact) { key = exact }
        else if candidates.count == 1, let only = candidates.first { key = only }
        else { throw Failure.ambiguous }
        guard let original = positions[key], original > box else { throw Failure.ambiguous }
        // Smaller weights sort toward the right. Insert between Box and its
        // right neighbor; no global renumbering and no fixed screen coordinate.
        let right = positions.filter { $0.key != key && $0.value < box }.map(\.value).max() ?? 0
        let temporary = right + (box - right) / 2
        guard temporary > right, temporary < box else { throw Failure.ambiguous }
        return Change(token: UUID(), key: key, original: original, temporary: temporary)
    }

    static func applying(_ change: Change, to current: [String: Double]) throws -> [String: Double] {
        guard current[change.key] == change.original else { throw Failure.changed }
        var result = current
        result[change.key] = change.temporary
        return result
    }

    static func restoring(_ change: Change, in current: [String: Double]) -> [String: Double] {
        // A manual move or deletion made during the menu takes precedence.
        guard current[change.key] == change.temporary else { return current }
        var result = current
        result[change.key] = change.original
        return result
    }

    private static func preferences() throws -> UserDefaults {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let data = try? Data(contentsOf: file),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let defaults = MenuBarAccessDiagnostics.containerDefaults(container, suiteName: "com.apple.MenuBar") else {
            throw Failure.unavailable
        }
        _ = try decode(root[preferenceKey])
        _ = try decode(defaults.object(forKey: preferenceKey))
        return defaults
    }

    private static func write(_ positions: [String: Double], replacing expected: [String: Double],
                              defaults: UserDefaults) throws {
        guard try decode(defaults.object(forKey: preferenceKey)) == expected else { throw Failure.changed }
        defaults.set(positions, forKey: preferenceKey)
        guard defaults.synchronize(), try decode(defaults.object(forKey: preferenceKey)) == positions else {
            throw Failure.write
        }
    }

    static func begin(bundle: String, identifier: String) throws -> Change {
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw Failure.pending }
        let defaults = try preferences()
        let current = try decode(defaults.object(forKey: preferenceKey))
        let change = try plan(bundle: bundle, identifier: identifier, positions: current)
        let updated = try applying(change, to: current)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PropertyListEncoder().encode(change).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        do { try write(updated, replacing: current, defaults: defaults) }
        catch { try? restore(token: change.token); throw error }
        return change
    }

    static func restore(token: UUID? = nil) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let change = try PropertyListDecoder().decode(Change.self, from: Data(contentsOf: journalURL))
        guard token == nil || token == change.token else { return }
        guard change.key.hasPrefix("status:"), !change.key.hasPrefix("status:com.apple."),
              !change.key.hasPrefix("status:\(NativeMenuBarPreferences.ownBundle)::"),
              change.original.isFinite, change.temporary.isFinite, change.original > change.temporary,
              change.temporary >= 0 else { throw Failure.ambiguous }
        let defaults = try preferences()
        let current = try decode(defaults.object(forKey: preferenceKey))
        let restored = restoring(change, in: current)
        if current != restored { try write(restored, replacing: current, defaults: defaults) }
        try FileManager.default.removeItem(at: journalURL)
    }
}
