import AppKit
import Darwin

// Public entry points are called by the main-thread AppKit controller. Async
// setup and all cross-process callbacks explicitly return to the main actor.
final class NativeMenuBarHiding: @unchecked Sendable {
    var onChange: ((Bool, String?) -> Void)?
    var setMarkerHidden: ((Bool) -> Void)?
    private(set) var wantsHidden = false
    private(set) var isHidden = false
    private(set) var isTransitioning = false
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var helper: Process?
    private var helperSetup: Task<Void, Error>?
    private var keepAlive: FileHandle?
    private var baseline: NativeMenuBarSnapshot?
    private(set) var hiddenApplications = Set<String>()

    func hide() {
        trace("hide requested")
        dispatchPrecondition(condition: .onQueue(.main))
        if wantsHidden && (isHidden || isTransitioning) { return }
        guard show() else { return }
        wantsHidden = true
        isTransitioning = true
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preferences = try NativeMenuBarPreferences()
                try await self.ensureHelper()
                // A preceding reveal restores the marker asynchronously in
                // MenuBarAgent. Resolve the boundary after it is registered.
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                let snapshot = try NativeMenuBarSnapshot.capture()
                let plan = try snapshot.plan()
                guard !plan.applicationKeys.isEmpty else {
                    self.wantsHidden = false
                    self.isTransitioning = false
                    self.onChange?(false, nil)
                    return
                }
                let document = try preferences.read()
                let visible = Set(snapshot.bars.flatMap(\.items).map(\.bundle))
                let keys = try NativeMenuBarPreferences.controlKeys(
                    for: plan.applicationKeys, visible: visible, executables: snapshot.executables, in: document
                )
                let changes = Dictionary(uniqueKeysWithValues: keys.map { ($0, false) })
                let added = NativeMenuBarPreferences.missingSelfLocations(for: plan.applicationKeys,
                    keys: keys, executables: snapshot.executables, in: document)
                let data = try NativeMenuBarPreferences.changing(document, allowed: changes, includingSelfLocations: added)
                let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, document.records[$0]!.allowed) })
                try NativeMenuBarRecovery.save(.init(original: document.data, written: data,
                    previousAllowed: previous, addedSelfLocations: added))
                try preferences.write(data, replacing: document.data)
                // Apply both visibility changes before yielding to verification;
                // waiting for the apps first makes the marker visibly lag behind.
                self.setMarkerHidden?(true)
                var verified = false
                for _ in 0..<6 {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    if let actual = try? NativeMenuBarSnapshot.capture(markerHidden: true),
                       (try? actual.verifyHidden(plan.applicationKeys, comparedTo: snapshot, markerHidden: true)) != nil {
                        verified = true
                        break
                    }
                }
                guard verified else { throw NativeMenuBarSnapshot.Failure.verification }
                self.baseline = snapshot
                self.hiddenApplications = plan.applicationKeys
                self.isHidden = true
                self.isTransitioning = false
                self.trace("hidden: " + plan.applicationKeys.sorted().joined(separator: ","))
                self.onChange?(true, nil)
            } catch {
                guard self.generation == current else { return }
                let message = error.localizedDescription
                self.trace("hide failed: " + message)
                if self.show() { self.onChange?(false, message) }
            }
        }
    }

    @discardableResult
    func show() -> Bool {
        trace("show requested")
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        operation?.cancel()
        operation = nil
        wantsHidden = false
        isTransitioning = false
        setMarkerHidden?(false)
        do {
            try NativeMenuBarRecovery.restore()
            isHidden = false
            baseline = nil
            hiddenApplications = []
            onChange?(false, nil)
            return true
        } catch {
            onChange?(isHidden, "Could not restore the menu bar: \(error.localizedDescription)")
            return false
        }
    }

    func verifyAfterFocusChange() {
        guard isHidden, !isTransitioning, let baseline else { return }
        do {
            try NativeMenuBarSnapshot.capture(markerHidden: true)
                .verifyHidden(hiddenApplications, comparedTo: baseline, markerHidden: true)
        } catch { trace("focus verification failed: " + error.localizedDescription); _ = show() }
    }

    func environmentChanged() {
        guard isHidden, !isTransitioning else { return }
        // Restore the complete section before recapturing membership. A new app
        // must never inherit the membership of a disappeared AX item or old PID.
        trace("environment changed")
        if show() {
            let expected = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == expected else { return }
                self.hide()
            }
        }
    }

    func stop() {
        trace("stop requested")
        _ = show()
        try? keepAlive?.close()
        keepAlive = nil
        helper = nil
    }

    private func trace(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MenuBox/Diagnostics", isDirectory: true)
        let file = directory.appendingPathComponent("native-hiding.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = previous.split(separator: "\n").suffix(79).map(String.init) +
            [ISO8601DateFormatter().string(from: Date()) + " " + message]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @MainActor private func ensureHelper() async throws {
        if helper?.isRunning == true { return }
        if let helperSetup { return try await helperSetup.value }
        let setup = Task { @MainActor in try await self.startHelper() }
        helperSetup = setup
        defer { helperSetup = nil }
        try await setup.value
    }

    @MainActor private func startHelper() async throws {
        guard let executable = Bundle.main.executableURL else { throw NativeMenuBarPreferences.Failure.access }
        let process = Process()
        let lifetime = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--menubox-visibility-recovery"]
        process.standardInput = lifetime
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        try process.run()
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            let data = output.fileHandleForReading.readDataToEndOfFile()
                            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if process.isRunning { process.terminate() }
                    throw NativeMenuBarPreferences.Failure.access
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            guard response == "READY\n", process.isRunning else { throw NativeMenuBarPreferences.Failure.access }
            keepAlive = lifetime.fileHandleForWriting
            helper = process
            process.terminationHandler = { [weak self] _ in
                process.terminationHandler = nil
                DispatchQueue.main.async {
                    guard let self, self.helper === process else { return }
                    self.trace("recovery helper exited")
                    self.helper = nil
                    self.keepAlive = nil
                    _ = self.show()
                }
            }
        } catch {
            try? lifetime.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
