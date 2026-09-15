import Foundation

/// Opt-in development experiment, restricted to one previously verified app.
/// This is not the production hiding backend. A journal allows recovery on the
/// next launch and normal quit if the bounded experiment is interrupted.
@MainActor
enum MenuBarVisibilityRoundTripProbe {
    private static let target = "com.electron.ollama"
    private static let key = "trackedApplications"
    private static let requestKey = "MenuBoxRunOllamaVisibilityProbe"
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MenuBox/Diagnostics", isDirectory: true)
    private static let journalURL = directory.appendingPathComponent("visibility-probe-journal.plist")
    private static let reportURL = directory.appendingPathComponent("visibility-probe-result.json")
    private static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter", isDirectory: true)

    private enum Failure: Error { case unreadable, unexpectedSchema, ambiguousTarget, changedDuringProbe, writeFailed }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            restorePending()
            return
        }
        guard UserDefaults.standard.bool(forKey: requestKey) else { return }
        Task { @MainActor in
            // Let the app register both of its own status items before testing.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await run()
        }
    }

    private static func locationBundle(_ value: Any?) -> String? {
        ((value as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }

    private static func read(_ defaults: UserDefaults) throws -> (Data, [Any], Int) {
        guard let data = defaults.data(forKey: key),
              let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              entries.count.isMultiple(of: 2) else { throw Failure.unreadable }
        let matches = stride(from: 0, to: entries.count, by: 2).filter {
            locationBundle(entries[$0]) == target
        }
        guard matches.count == 1, let index = matches.first,
              let record = entries[index + 1] as? [String: Any],
              locationBundle(record["location"]) == target,
              let allowed = record["isAllowed"] as? NSNumber,
              CFGetTypeID(allowed) == CFBooleanGetTypeID(),
              let locations = record["menuItemLocations"] as? [Any],
              locations.allSatisfy({ locationBundle($0) == target }) else {
            throw Failure.ambiguousTarget
        }
        return (data, entries, index + 1)
    }

    private static func changed(_ entries: [Any], index: Int, allowed: Bool) throws -> Data {
        var result = entries
        guard var record = result[index] as? [String: Any] else { throw Failure.unexpectedSchema }
        record["isAllowed"] = allowed
        result[index] = record
        return try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
    }

    private static func report(_ stage: String, _ extra: [String: Any] = [:]) {
        var value = extra
        value["stage"] = stage
        value["target"] = target
        value["capturedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        } catch { NSLog("[MenuBox] Visibility probe report failed: %@", String(describing: error)) }
    }

    private static func run() async {
        do {
            // A successful ordinary file read is required before using the
            // explicitly located preferences domain. Never bypass an access denial.
            let file = container.appendingPathComponent("Library/Preferences/group.com.apple.controlcenter.plist")
            let disk = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
            guard let defaults = MenuBarAccessDiagnostics.containerDefaults(container) else { throw Failure.unreadable }
            let (original, entries, index) = try read(defaults)
            guard ((disk as? [String: Any])?[key] as? Data) == original else { throw Failure.changedDuringProbe }
            guard (entries[index] as? [String: Any])?["isAllowed"] as? Bool == true else {
                report("skippedAlreadyDisabled")
                UserDefaults.standard.removeObject(forKey: requestKey)
                return
            }
            let hidden = try changed(entries, index: index, allowed: false)
            let journal: [String: Any] = ["target": target, "original": original, "written": hidden]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0)
                .write(to: journalURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: requestKey)
            guard defaults.data(forKey: key) == original else { throw Failure.changedDuringProbe }
            defaults.set(hidden, forKey: key)
            guard defaults.synchronize(), defaults.data(forKey: key) == hidden else { throw Failure.writeFailed }
            report("hiddenSettingWritten", ["holdSeconds": 20, "writesAttempted": true])
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            restorePending()
        } catch {
            report("failed", ["error": String(describing: error)])
            if FileManager.default.fileExists(atPath: journalURL.path) { restorePending() }
        }
    }

    static func restorePending() {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        do {
            guard let journal = try PropertyListSerialization.propertyList(from: Data(contentsOf: journalURL), format: nil) as? [String: Any],
                  journal["target"] as? String == target,
                  let original = journal["original"] as? Data,
                  let written = journal["written"] as? Data,
                  let defaults = MenuBarAccessDiagnostics.containerDefaults(container) else { throw Failure.unreadable }
            let (current, entries, index) = try read(defaults)
            let restored: Data
            if current == written {
                restored = original
            } else {
                // Preserve concurrent changes to unrelated records and fields.
                restored = try changed(entries, index: index, allowed: true)
            }
            defaults.set(restored, forKey: key)
            guard defaults.synchronize(), defaults.data(forKey: key) == restored else { throw Failure.writeFailed }
            try FileManager.default.removeItem(at: journalURL)
            report("restored", ["originalBytesRestored": restored == original, "writesAttempted": true])
        } catch {
            report("recoveryRequired", ["error": String(describing: error)])
        }
    }
}
