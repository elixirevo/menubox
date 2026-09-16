import Foundation

enum NativeMenuBarRecovery {
    struct Journal: Codable {
        let original: Data
        let written: Data
        let previousAllowed: [String: Bool]
        var addedSelfLocations: Set<String>? = nil
        var systemChanges: [NativeSystemMenuBarPreferences.Change]? = nil
    }
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MenuBox/Visibility", isDirectory: true)
    static let journalURL = directory.appendingPathComponent("pending.plist")

    static var hasPending: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    static func save(_ journal: Journal) throws {
        guard !hasPending else { throw NativeMenuBarPreferences.Failure.concurrentChange }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try PropertyListEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    static func restore() throws {
        guard hasPending else { return }
        let journal = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        let preferences = try NativeMenuBarPreferences()
        let current = try preferences.read()
        let restored = try restorationData(journal, current: current)
        if current.data != restored { try preferences.write(restored, replacing: current.data) }
        try NativeSystemMenuBarPreferences.restore(journal.systemChanges ?? [])
        try FileManager.default.removeItem(at: journalURL)
    }

    static func reapply() throws {
        let journal = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        let preferences = try NativeMenuBarPreferences()
        let current = try preferences.read()
        let data = try reapplicationData(journal, current: current)
        if current.data != data { try preferences.write(data, replacing: current.data) }
        try NativeSystemMenuBarPreferences.reapply(journal.systemChanges ?? [])
    }

    static func reapplicationData(_ journal: Journal, current: NativeMenuBarPreferences.Document) throws -> Data {
        // Validate the existing journal but never replace its original values
        // with already-hidden values during wake/recovery.
        _ = try restorationData(journal, current: current)
        let written = try NativeMenuBarPreferences.decode(journal.written)
        for key in journal.previousAllowed.keys {
            guard let record = current.records[key], let expected = written.records[key] else {
                throw NativeMenuBarPreferences.Failure.missing(key)
            }
            let locations = NSArray(array: expected.locations)
            guard record.locations.allSatisfy({ locations.contains($0) }) else {
                throw NativeMenuBarPreferences.Failure.shared(key)
            }
        }
        return try NativeMenuBarPreferences.changing(current,
            allowed: journal.previousAllowed.mapValues { _ in false },
            includingSelfLocations: journal.addedSelfLocations ?? [])
    }

    static func restorationData(_ journal: Journal, current: NativeMenuBarPreferences.Document) throws -> Data {
        let original = try NativeMenuBarPreferences.decode(journal.original)
        try NativeSystemMenuBarPreferences.validate(journal.systemChanges ?? [])
        guard !journal.previousAllowed.isEmpty || !(journal.systemChanges ?? []).isEmpty else {
            throw NativeMenuBarPreferences.Failure.schema
        }
        guard
              journal.previousAllowed.allSatisfy({ key, value in
                  key != NativeMenuBarPreferences.ownBundle && original.records[key]?.allowed == value
              }) else {
            throw NativeMenuBarPreferences.Failure.schema
        }
        let added = journal.addedSelfLocations ?? []
        guard added.isSubset(of: Set(journal.previousAllowed.keys)),
              added.allSatisfy({ key in
                  original.records[key]?.locations.contains { NativeMenuBarPreferences.bundle($0) == key } == false
              }) else { throw NativeMenuBarPreferences.Failure.schema }
        let expected = try NativeMenuBarPreferences.decode(NativeMenuBarPreferences.changing(original,
            allowed: journal.previousAllowed.mapValues { _ in false }, includingSelfLocations: added))
        let written = try NativeMenuBarPreferences.decode(journal.written)
        // Binary plist dictionary ordering is not an identity guarantee.
        guard NSArray(array: expected.entries).isEqual(to: written.entries) else {
            throw NativeMenuBarPreferences.Failure.schema
        }
        // Keep the corrected ownership metadata. Removing a newly introduced
        // location in the same update that re-enables it leaves MenuBarAgent's
        // live item disabled: it no longer sees that location to restore it.
        // Only visibility is temporary; repairing a stale owner association is
        // retained, along with all previous locations and unrelated fields.
        if current.data == original.data || current.data == journal.written {
            if added.isEmpty { return journal.original }
            return try NativeMenuBarPreferences.changing(original, allowed: journal.previousAllowed,
                                                         includingSelfLocations: added)
        }
        return try NativeMenuBarPreferences.changing(current, allowed: journal.previousAllowed,
                                                     includingSelfLocations: added)
    }

    /// A copy of this signed executable waits for the parent's pipe to close.
    /// No UI, updater, additional privilege, or shell is launched in this mode.
    static func runHelper() -> Int32 {
        do {
            _ = try NativeMenuBarPreferences()
            FileHandle.standardOutput.write(Data("READY\n".utf8))
            try FileHandle.standardOutput.close()
            _ = FileHandle.standardInput.readDataToEndOfFile()
            try restore()
            return 0
        } catch {
            FileHandle.standardError.write(Data("MenuBox recovery failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
