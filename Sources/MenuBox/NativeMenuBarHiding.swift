import AppKit
import Darwin

// Public entry points are called by the main-thread AppKit controller. Async
// setup and all cross-process callbacks explicitly return to the main actor.
final class NativeMenuBarHiding: @unchecked Sendable {
    struct Backend {
        var capture: (Bool) throws -> NativeMenuBarSnapshot
        var apply: (NativeMenuBarSnapshot, MenuBarSectionPlanner.Plan) throws -> Void
        var restore: () throws -> Void
        var reapply: (NativeMenuBarSnapshot, MenuBarSectionPlanner.Plan) throws -> Void
        var prepare: (() async throws -> Void)?
        var log: ((String) -> Void)?

        static var live: Backend {
            .init(capture: { try NativeMenuBarSnapshot.capture(markerHidden: $0) },
                  apply: NativeMenuBarHiding.applyVisibility,
                  restore: NativeMenuBarRecovery.restore,
                  reapply: { snapshot, plan in
                      if NativeMenuBarRecovery.hasPending { try NativeMenuBarRecovery.reapply() }
                      else { try NativeMenuBarHiding.applyVisibility(snapshot, plan) }
                  })
        }
    }
    struct Timing {
        var initial: UInt64 = 250_000_000
        var environment: UInt64 = 750_000_000
        var verification: UInt64 = 250_000_000
        var retries: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 3_000_000_000]
    }
    var onChange: ((Bool, String?) -> Void)?
    var setMarkerHidden: ((Bool) -> Void)?
    private(set) var wantsHidden = false
    private(set) var isHidden = false
    private(set) var isTransitioning = false
    private var isSuspended = false
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var helper: Process?
    private var helperSetup: Task<Void, Error>?
    private var keepAlive: FileHandle?
    private var baseline: NativeMenuBarSnapshot?
    private var appliedPlan: MenuBarSectionPlanner.Plan?
    private var checkRequested = false
    private(set) var hiddenApplications = Set<String>()
    private(set) var hiddenSystemItems = Set<String>()
    private let backend: Backend
    private let timing: Timing

    init(backend: Backend = .live, timing: Timing = Timing()) {
        self.backend = backend
        self.timing = timing
    }

    func hide() {
        trace("hide requested")
        dispatchPrecondition(condition: .onQueue(.main))
        if wantsHidden && (isHidden || isTransitioning) { return }
        guard restoreVisibility(preservingIntent: false) else { return }
        wantsHidden = true
        if !isSuspended { startAttempt(delay: timing.initial) }
    }

    private func startAttempt(delay: UInt64, retry: Int = 0) {
        guard wantsHidden, !isSuspended else { return }
        isTransitioning = true
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let prepare = self.backend.prepare { try await prepare() }
                else { try await self.ensureHelper() }
                // The marker and display hosts register asynchronously after
                // reveal/wake. Retry transient layouts without losing user intent.
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                let snapshot = try self.backend.capture(false)
                let plan = try snapshot.plan()
                try self.backend.apply(snapshot, plan)
                self.setMarkerHidden?(true)
                // Record the applied transaction before awaiting verification so
                // sleep during verification can retain it and its original journal.
                self.baseline = snapshot
                self.appliedPlan = plan
                self.hiddenApplications = plan.applicationKeys
                self.hiddenSystemItems = plan.systemItemIDs
                self.isHidden = true
                self.startReconciliation(delay: self.timing.verification)
            } catch {
                guard self.generation == current else { return }
                let message = error.localizedDescription
                self.trace("hide failed (attempt \(retry + 1)): " + String(describing: error) + " — " + message)
                let retryable = Self.isTransient(error)
                guard self.restoreVisibility(preservingIntent: retryable) else { return }
                if retryable, retry < self.timing.retries.count, !self.isSuspended {
                    self.startAttempt(delay: self.timing.retries[retry], retry: retry + 1)
                } else {
                    self.operation = nil
                    self.onChange?(false, message)
                }
            }
        }
    }

    /// Observe an existing transaction without revealing icons. Only a confirmed
    /// change of membership/displays needs the marker restored for a new plan.
    private func startReconciliation(delay: UInt64) {
        guard wantsHidden, !isSuspended, let baseline, let plan = appliedPlan else { return }
        isTransitioning = true
        checkRequested = false
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var nextDelay = delay
            var changedLayout: String?
            var targetsStillVisible = false
            for attempt in 0...self.timing.retries.count {
                do {
                    if let prepare = self.backend.prepare { try await prepare() }
                    else { try await self.ensureHelper() }
                    try await Task.sleep(nanoseconds: nextDelay)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    self.setMarkerHidden?(true)
                    let actual = try self.backend.capture(true)
                    switch try actual.hiddenState(plan.applicationKeys, comparedTo: baseline,
                                                  systemItems: plan.systemItemIDs) {
                    case .hidden:
                        self.isHidden = true
                        self.isTransitioning = false
                        self.operation = nil
                        self.trace("hidden: " + plan.applicationKeys.sorted().joined(separator: ",") +
                                   "; systems: " + plan.systemItemIDs.sorted().joined(separator: ","))
                        self.onChange?(true, nil)
                        if self.checkRequested { self.startReconciliation(delay: self.timing.environment) }
                        return
                    case .targetsVisible:
                        targetsStillVisible = true
                        changedLayout = nil
                        try self.backend.reapply(baseline, plan)
                        self.trace("reapplied existing transaction without reveal")
                        nextDelay = self.timing.verification
                    case .layoutChanged:
                        targetsStillVisible = false
                        let signature = actual.membershipSignature
                        if changedLayout == signature {
                            self.trace("stable layout change: replan section")
                            if self.restoreVisibility(preservingIntent: true) {
                                self.startAttempt(delay: self.timing.initial)
                            }
                            return
                        }
                        changedLayout = signature
                        nextDelay = self.timing.environment
                    }
                } catch {
                    guard self.generation == current else { return }
                    self.trace("hidden check deferred (attempt \(attempt + 1)): " + String(describing: error))
                    changedLayout = nil
                    targetsStillVisible = false
                    if !Self.isTransient(error) {
                        _ = self.restoreVisibility(preservingIntent: false)
                        self.onChange?(self.isHidden, error.localizedDescription)
                        return
                    }
                    nextDelay = attempt < self.timing.retries.count ? self.timing.retries[attempt] : self.timing.environment
                }
            }
            guard self.generation == current else { return }
            self.operation = nil
            self.isTransitioning = false
            if targetsStillVisible {
                _ = self.restoreVisibility(preservingIntent: false)
                self.onChange?(self.isHidden, NativeMenuBarSnapshot.Failure.verification.localizedDescription)
                return
            }
            // An unavailable AX tree is not evidence that hidden settings should
            // be undone. Keep the transaction; the next event can retry checking.
            self.trace("hidden check pending: keeping existing transaction")
            if self.checkRequested { self.startReconciliation(delay: self.timing.environment) }
        }
    }

    private static func applyVisibility(_ snapshot: NativeMenuBarSnapshot, _ plan: MenuBarSectionPlanner.Plan) throws {
        let applications = plan.applicationKeys
        guard !applications.isEmpty || !plan.systemItemIDs.isEmpty else { return }
        let systemChanges = try NativeSystemMenuBarPreferences.prepare(plan.systemItemIDs)
        let preferences = try NativeMenuBarPreferences()
        let document = try preferences.read()
        let visible = Set(snapshot.bars.flatMap(\.items).map(\.bundle))
        let keys = try NativeMenuBarPreferences.controlKeys(
            for: applications, visible: visible, executables: snapshot.executables, in: document)
        let changes = Dictionary(uniqueKeysWithValues: keys.map { ($0, false) })
        let added = NativeMenuBarPreferences.missingSelfLocations(for: applications,
            keys: keys, executables: snapshot.executables, in: document)
        let data = try NativeMenuBarPreferences.changing(document, allowed: changes, includingSelfLocations: added)
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, document.records[$0]!.allowed) })
        try NativeMenuBarRecovery.save(.init(original: document.data, written: data,
            previousAllowed: previous, addedSelfLocations: added, systemChanges: systemChanges))
        try preferences.write(data, replacing: document.data)
        try NativeSystemMenuBarPreferences.apply(systemChanges)
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case NativeMenuBarSnapshot.Failure.incomplete, NativeMenuBarSnapshot.Failure.boundary,
             NativeMenuBarSnapshot.Failure.verification,
             MenuBarSectionPlanner.Failure.incompleteSnapshot,
             MenuBarSectionPlanner.Failure.missingOrAmbiguousControls,
             MenuBarSectionPlanner.Failure.ambiguousGeometry,
             NativeMenuBarPreferences.Failure.concurrentChange, NativeSystemMenuBarPreferences.Failure.concurrentChange:
            return true
        default: return false
        }
    }

    @discardableResult
    func show() -> Bool {
        trace("show requested")
        return restoreVisibility(preservingIntent: false)
    }

    @discardableResult
    private func restoreVisibility(preservingIntent: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        operation?.cancel()
        operation = nil
        if !preservingIntent { wantsHidden = false }
        isTransitioning = false
        setMarkerHidden?(false)
        do {
            try backend.restore()
            isHidden = false
            baseline = nil
            appliedPlan = nil
            checkRequested = false
            hiddenApplications = []
            hiddenSystemItems = []
            onChange?(false, nil)
            return true
        } catch {
            onChange?(isHidden, "Could not restore the menu bar: \(error.localizedDescription)")
            return false
        }
    }

    func verifyAfterFocusChange() {
        guard isHidden else { return }
        environmentChanged(reason: "focus")
    }

    func environmentChanged(reason: String = "environment") {
        guard wantsHidden, !isSuspended else { return }
        trace("check requested: " + reason)
        if operation != nil {
            checkRequested = true
            return
        }
        if baseline != nil { startReconciliation(delay: timing.environment) }
        else { startAttempt(delay: timing.environment) }
    }

    func suspend() {
        guard !isSuspended else { return }
        trace("sleep: retain hidden transaction=\(baseline != nil), intent=\(wantsHidden)")
        isSuspended = true
        generation = UUID()
        operation?.cancel()
        operation = nil
        isTransitioning = false
        checkRequested = false
    }

    func resume(reason: String = "wake") {
        let wasSuspended = isSuspended
        isSuspended = false
        trace("wake: retain hidden transaction=\(baseline != nil), intent=\(wantsHidden); " + reason)
        if wasSuspended, wantsHidden, baseline != nil {
            startReconciliation(delay: 0)
        } else {
            environmentChanged(reason: reason)
        }
    }

    func stop() {
        trace("stop requested")
        _ = show()
        try? keepAlive?.close()
        keepAlive = nil
        helper = nil
    }

    func recordMenuInteraction(_ message: String) { trace("box menu: " + message) }

    private func trace(_ message: String) {
        if let log = backend.log { log(message); return }
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
                    self.environmentChanged()
                }
            }
        } catch {
            try? lifetime.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
