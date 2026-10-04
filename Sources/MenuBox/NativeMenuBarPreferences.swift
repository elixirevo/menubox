// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation
import CoreFoundation

/// Container-scoped preferences access, verified against the actual stored key.
/// Full Disk Access is required; no Apple-only entitlement is added to the app.
final class NativeMenuBarPreferences {
    static let ownBundle = "com.elixirevo.MenuBox"
    // These processes host multiple independent controls. Never toggle the
    // entire host merely because it appears in the app preference store.
    static let sharedSystemHosts: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter"]
    static let key = "trackedApplications"
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter", isDirectory: true)
    private let defaults: UserDefaults

    struct Document {
        let data: Data
        let entries: [Any]
        let records: [String: Record]
    }
    struct Record {
        let index: Int
        let allowed: Bool
        let locations: [Any]
    }
    enum Failure: LocalizedError {
        case access, schema, missing(String), shared(String), concurrentChange, write
        var errorDescription: String? {
            switch self {
            case .access: return "MenuBox needs Full Disk Access to hide icons on macOS 27."
            case .schema: return "The menu bar settings format is not supported."
            case .missing(let app): return "Cannot resolve menu bar settings for \(app)."
            case .shared(let app): return "Hiding \(app) would also affect an icon outside the selected section."
            case .concurrentChange: return "Menu bar settings changed. Please try again."
            case .write: return "macOS did not confirm the menu bar setting change."
            }
        }
    }

    init() throws {
        guard (try? Data(contentsOf: Self.file)) != nil,
              let defaults = MenuBarAccessDiagnostics.containerDefaults(Self.container) else { throw Failure.access }
        self.defaults = defaults
        _ = try read()
    }

    static var file: URL {
        container.appendingPathComponent("Library/Preferences/group.com.apple.controlcenter.plist")
    }

    static func bundle(_ location: Any?) -> String? {
        ((location as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }

    static func executable(_ location: Any?) -> URL? {
        guard let adhoc = (location as? [String: Any])?["adhocBinary"] as? [String: Any],
              let representation = adhoc["_0"] as? [String: Any],
              let relative = representation["relative"] as? String,
              let url = URL(string: relative), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    static func decode(_ data: Data) throws -> Document {
        guard let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              entries.count.isMultiple(of: 2) else { throw Failure.schema }
        var records: [String: Record] = [:]
        for index in stride(from: 0, to: entries.count, by: 2) {
            // Preserve unknown location kinds verbatim, but never control them.
            guard let bundle = bundle(entries[index]) else { continue }
            guard records[bundle] == nil,
                  let value = entries[index + 1] as? [String: Any],
                  Self.bundle(value["location"]) == bundle,
                  let allowed = value["isAllowed"] as? NSNumber,
                  CFGetTypeID(allowed) == CFBooleanGetTypeID(),
                  let locations = value["menuItemLocations"] as? [Any] else { throw Failure.schema }
            records[bundle] = Record(index: index + 1, allowed: allowed.boolValue, locations: locations)
        }
        return Document(data: data, entries: entries, records: records)
    }

    func read() throws -> Document {
        guard let data = defaults.data(forKey: Self.key) else { throw Failure.access }
        return try Self.decode(data)
    }

    static func controlKeys(for selected: Set<String>, visible: Set<String>, executables: [String: URL],
                            in document: Document) throws -> Set<String> {
        guard !selected.contains(ownBundle) else { throw Failure.shared(ownBundle) }
        if let host = selected.intersection(sharedSystemHosts).sorted().first { throw Failure.shared(host) }
        var keys = Set<String>()
        for app in selected {
            let candidates = controllingRecords(for: app, executables: executables, in: document)
            guard candidates.count == 1, let key = candidates.first,
                  let record = document.records[key], record.allowed else { throw Failure.missing(app) }
            let affected = Set(record.locations.compactMap { affectedBundle($0, executables: executables) }).union([key])
            guard !affected.contains(ownBundle), affected.isDisjoint(with: sharedSystemHosts),
                  affected.intersection(visible).isSubset(of: selected) else {
                throw Failure.shared(app)
            }
            keys.insert(key)
        }
        return keys
    }

    /// Ownership discovery also works while our journal has the record hidden.
    /// Allowed flags and collateral effects are checked again before any write.
    static func applicationControlBundles(_ bundles: Set<String>, executables: [String: URL],
                                          in document: Document) -> Set<String> {
        Set(bundles.subtracting(sharedSystemHosts).subtracting([ownBundle]).filter {
            let candidates = controllingRecords(for: $0, executables: executables, in: document)
            guard candidates.count == 1, let key = candidates.first, let record = document.records[key] else { return false }
            let affected = Set(record.locations.compactMap { affectedBundle($0, executables: executables) }).union([key])
            return !affected.contains(ownBundle) && affected.isDisjoint(with: sharedSystemHosts)
        })
    }

    private static func controllingRecords(for app: String, executables: [String: URL],
                                           in document: Document) -> [String] {
        if document.records[app] != nil { return [app] }
        return document.records.filter {
            $0.value.locations.contains { affectedBundle($0, executables: executables) == app }
        }.map(\.key)
    }

    private static func affectedBundle(_ location: Any, executables: [String: URL]) -> String? {
        if let bundle = bundle(location) { return bundle }
        if let url = executable(location) {
            return executables.first { $0.value.standardizedFileURL == url }?.key
        }
        return nil
    }

    static func missingSelfLocations(for selected: Set<String>, keys: Set<String>,
                                     executables: [String: URL], in document: Document) -> Set<String> {
        // macOS can retain a launcher's record containing only an old child
        // executable. Its isAllowed flag then has no effect on the launcher's
        // own icon. Add only the live, selected record owner's identity for the
        // live menu item. Recovery restores visibility and retains the corrected
        // association so MenuBarAgent can re-enable that same item.
        Set(selected.intersection(keys).filter { app in
            guard let record = document.records[app] else { return false }
            return !record.locations.contains { location in
                bundle(location) == app ||
                    (executable(location) != nil && executable(location) == executables[app]?.standardizedFileURL)
            }
        })
    }

    static func changing(_ document: Document, allowed: [String: Bool],
                         includingSelfLocations: Set<String> = [],
                         removingSelfLocations: Set<String> = []) throws -> Data {
        var entries = document.entries
        guard includingSelfLocations.union(removingSelfLocations).isSubset(of: Set(allowed.keys)) else {
            throw Failure.schema
        }
        for (key, flag) in allowed {
            guard key != ownBundle, !sharedSystemHosts.contains(key), let record = document.records[key],
                  var value = entries[record.index] as? [String: Any] else { throw Failure.missing(key) }
            value["isAllowed"] = flag
            var locations = record.locations
            if removingSelfLocations.contains(key) { locations.removeAll { bundle($0) == key } }
            if includingSelfLocations.contains(key), !locations.contains(where: { bundle($0) == key }) {
                locations.append(["bundle": ["_0": key]])
            }
            value["menuItemLocations"] = locations
            entries[record.index] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    func write(_ data: Data, replacing expected: Data) throws {
        guard defaults.data(forKey: Self.key) == expected else { throw Failure.concurrentChange }
        defaults.set(data, forKey: Self.key)
        guard defaults.synchronize(), defaults.data(forKey: Self.key) == data else { throw Failure.write }
    }
}
