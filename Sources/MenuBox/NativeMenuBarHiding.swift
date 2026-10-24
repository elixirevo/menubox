// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

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
        var stageExtension: ((NativeMenuBarSnapshot, MenuBarSectionPlanner.Plan, MenuBarSectionPlanner.Plan) throws -> Void)? = nil
        var temporarilyReveal: ((String, NativeMenuBarSnapshot) throws -> Void)? = nil
        var finishRestore: (() throws -> Void)? = nil
        var pendingApplications: (() -> Set<String>)? = nil
        var hasPendingRestore: (() -> Bool)? = nil
        var refinePlan: ((NativeMenuBarSnapshot, MenuBarSectionPlanner.Plan) throws -> MenuBarSectionPlanner.Plan)? = nil
        var retainPlan: ((NativeMenuBarSnapshot, MenuBarSectionPlanner.Plan) throws -> Void)? = nil
        // Live finishRestore verifies persisted values before removing the journal.
        // Backends without that guarantee must still verify restored host membership.
        var settingsRestoreIsAuthoritative = false
        var prepare: (() async throws -> Void)?
        var log: ((String) -> Void)?

        static var live: Backend {
            .init(capture: { try NativeMenuBarSnapshot.capture(markerHidden: $0) },
                  apply: NativeMenuBarHiding.applyVisibility,
                  restore: NativeMenuBarRecovery.restore,
                  reapply: { snapshot, plan in
                      if NativeMenuBarRecovery.hasPending { try NativeMenuBarRecovery.reapply() }
                      else { try NativeMenuBarHiding.applyVisibility(snapshot, plan) }
                  }, stageExtension: NativeMenuBarHiding.stageExtension,
                  temporarilyReveal: NativeMenuBarRecovery.temporarilyReveal,
                  finishRestore: NativeMenuBarRecovery.completeRestore,
                  pendingApplications: NativeMenuBarRecovery.pendingApplications,
                  hasPendingRestore: { NativeMenuBarRecovery.hasPending },
                  refinePlan: NativeMenuBarHiding.preparePartialPlan,
                  retainPlan: NativeMenuBarRecovery.retain,
                  settingsRestoreIsAuthoritative: true)
        }
    }
    struct Timing {
        var initial: UInt64 = 0
        var environment: UInt64 = 750_000_000
        var verification: UInt64 = 250_000_000
        var retries: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 3_000_000_000]
    }
    private(set) var noticeIdentifier: String?
    private(set) var noticeTitle = menuBoxLocalized("Couldn’t hide menu bar icons")
    var onChange: ((Bool, String?) -> Void)?
    var setMarkerHidden: ((Bool) -> Void)?
    private(set) var wantsHidden = false
    private(set) var isHidden = false
    private(set) var isTransitioning = false
    private(set) var isRestoring = false
    private var reportedRestoreFailure = false
    private var isSuspended = false
    private var awaitingStatusItemRepair = false
    var canRepairStatusItems: Bool {
        // A missing local host makes capture/verification incomplete. Periodic
        // checks can keep reconciliation transitioning forever, so waiting for
        // an idle transition would also prevent the repair it needs to finish.
        // Keep the initial apply/verification protected until an incomplete read
        // confirms this condition. The caller still debounces raw host samples.
        !isSuspended && temporaryReveal == nil &&
            (!isTransitioning || baseline == nil || awaitingStatusItemRepair)
    }
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var helper: Process?
    private var helperSetup: Task<Void, Error>?
    private var keepAlive: FileHandle?
    private var baseline: NativeMenuBarSnapshot?
    private var boundaryReference: NativeMenuBarSnapshot?
    private var appliedPlan: MenuBarSectionPlanner.Plan?
    private var checkRequested = false
    private var temporaryReveal: (token: UUID, bundle: String)?
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
        if isRestoring {
            wantsHidden = true
            if operation == nil, !isSuspended { startRestoration() }
            return
        }
        if wantsHidden && (isHidden || isTransitioning) { return }
        guard restoreVisibility(preservingIntent: false) else { return }
        wantsHidden = true
        if !isSuspended, !isRestoring { startAttempt(delay: timing.initial) }
    }

    private func startAttempt(delay: UInt64, retry: Int = 0) {
        guard wantsHidden, !isSuspended, !isRestoring else { return }
        isTransitioning = true
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var failureTitle = "Couldn’t prepare icon recovery"
            do {
                if let prepare = self.backend.prepare { try await prepare() }
                else { try await self.ensureHelper() }
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                try Task.checkCancellation()
                guard self.generation == current else { return }
                failureTitle = "Couldn’t read the menu bar layout"
                let snapshot = try self.backend.capture(false)
                failureTitle = "Couldn’t determine which icons to hide"
                let proposed = try snapshot.plan(allowPartial: true)
                failureTitle = "Couldn’t read menu bar settings"
                let plan = try self.backend.refinePlan?(snapshot, proposed) ?? proposed
                if self.finishEmptyPlan(plan) { return }
                failureTitle = "Couldn’t apply menu bar settings"
                try self.backend.apply(snapshot, plan)
                // Queue the marker's host geometry in the same main-actor turn
                // as the visibility write. Presentation must not clear its image
                // or await an AX snapshot between these two layout requests.
                self.setMarkerHidden?(true)
                // Record the applied transaction before awaiting verification so
                // sleep during verification can retain it and its original journal.
                self.baseline = snapshot
                self.boundaryReference = snapshot
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
                    self.report(false, title: failureTitle, message: message)
                }
            }
        }
    }

    /// Observe an existing transaction without revealing icons. New items extend
    /// it in place; only a changed display topology requires a visible new plan.
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
            var lastActual: NativeMenuBarSnapshot?
            for attempt in 0...self.timing.retries.count {
                do {
                    if let prepare = self.backend.prepare { try await prepare() }
                    else { try await self.ensureHelper() }
                    try await Task.sleep(nanoseconds: nextDelay)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    self.setMarkerHidden?(true)
                    let actual = try self.backend.capture(true)
                    self.awaitingStatusItemRepair = false
                    lastActual = actual
                    switch try actual.excluding(plan.exclusions).hiddenState(plan.applicationKeys,
                        comparedTo: baseline.excluding(plan.exclusions), systemItems: plan.systemItemIDs) {
                    case .hidden:
                        self.isHidden = true
                        self.isTransitioning = false
                        self.operation = nil
                        self.trace("hidden: " + plan.applicationKeys.sorted().joined(separator: ",") +
                                   "; systems: " + plan.systemItemIDs.sorted().joined(separator: ","))
                        self.report(true, title: "Some icons were left visible", message: Self.partialMessage(plan),
                                    identifier: HidingNoticeIdentity.partial(plan))
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
                        if actual.bars.flatMap(\.items).contains(where: {
                            plan.applicationKeys.contains($0.bundle) || plan.systemItemIDs.contains($0.id) || $0.id == "MenuBox.marker"
                        }) {
                            targetsStillVisible = true
                            changedLayout = nil
                            try self.backend.reapply(baseline, plan)
                            nextDelay = self.timing.verification
                            continue
                        }
                        let signature = actual.membershipSignature
                        if changedLayout == signature {
                            if Set(actual.bars.map(\.id)) != Set(baseline.bars.map(\.id)) {
                                self.trace("display topology changed: replan section")
                                if self.restoreVisibility(preservingIntent: true) {
                                    self.startAttempt(delay: self.timing.initial)
                                }
                                return
                            }
                            do {
                                guard let reference = self.boundaryReference else { throw NativeMenuBarSnapshot.Failure.incomplete }
                                let update = try actual.excluding(plan.exclusions).addingItemsWhileHidden(
                                    comparedTo: baseline.excluding(plan.exclusions),
                                    boundaryReference: reference.excluding(plan.exclusions), plan: plan)
                                let updatedBaseline = update.baseline.includingExcluded(from: actual, exclusions: plan.exclusions)
                                var proposed = update.plan
                                proposed.exclusions = plan.exclusions
                                let next = try self.backend.refinePlan?(updatedBaseline, proposed) ?? proposed
                                let extendsHiding = next.applicationKeys != plan.applicationKeys || next.systemItemIDs != plan.systemItemIDs
                                if extendsHiding {
                                    var retained = plan
                                    for key in plan.applicationKeys.subtracting(next.applicationKeys) {
                                        retained = retained.excluding(.application(key), reason: "Changing this setting would also affect icons that must stay visible.")
                                    }
                                    for key in plan.systemItemIDs.subtracting(next.systemItemIDs) {
                                        retained = retained.excluding(.system(key), reason: "This macOS control does not have a supported hiding setting.")
                                    }
                                    if retained.applicationKeys != plan.applicationKeys || retained.systemItemIDs != plan.systemItemIDs {
                                        guard let retain = self.backend.retainPlan else { throw NativeMenuBarSnapshot.Failure.incomplete }
                                        try retain(updatedBaseline, retained)
                                        self.appliedPlan = retained
                                        self.hiddenApplications = retained.applicationKeys
                                        self.hiddenSystemItems = retained.systemItemIDs
                                    }
                                    guard let stage = self.backend.stageExtension else { throw NativeMenuBarSnapshot.Failure.incomplete }
                                    try stage(updatedBaseline, retained, next)
                                }
                                // Once journaled, keep the expanded intent even
                                // if applying needs a retry. Never restore first.
                                self.baseline = updatedBaseline
                                self.appliedPlan = next
                                self.hiddenApplications = next.applicationKeys
                                self.hiddenSystemItems = next.systemItemIDs
                                if extendsHiding {
                                    do { try self.backend.reapply(updatedBaseline, next) }
                                    catch { self.trace("extended transaction awaiting apply: \(error)") }
                                }
                                self.trace("extended section without reveal: " + next.applicationKeys.subtracting(plan.applicationKeys).sorted().joined(separator: ","))
                                self.startReconciliation(delay: self.timing.verification)
                                return
                            } catch {
                                // Incomplete hosts or ambiguous ownership are
                                // not permission to expose every hidden item.
                                self.trace("section update deferred; keep hidden: \(error)")
                                if self.appliedPlan != plan {
                                    self.startReconciliation(delay: self.timing.verification)
                                    return
                                }
                            }
                        }
                        changedLayout = signature
                        nextDelay = self.timing.environment
                    }
                } catch {
                    guard self.generation == current else { return }
                    if case NativeMenuBarSnapshot.Failure.incomplete = error {
                        self.awaitingStatusItemRepair = true
                    }
                    self.trace("hidden check deferred (attempt \(attempt + 1)): " + String(describing: error))
                    changedLayout = nil
                    targetsStillVisible = false
                    if let refine = self.backend.refinePlan, self.backend.retainPlan != nil {
                        do {
                            let reduced = try refine(baseline, plan)
                            if reduced.applicationKeys != plan.applicationKeys || reduced.systemItemIDs != plan.systemItemIDs {
                                try self.keepEligiblePlan(reduced, baseline: baseline)
                                return
                            }
                        } catch { self.trace("could not isolate failed icon: \(error)") }
                    }
                    if !Self.isTransient(error) {
                        if self.restoreVisibility(preservingIntent: false) {
                            self.report(self.isHidden, title: "Couldn’t apply menu bar settings", message: error.localizedDescription)
                        }
                        return
                    }
                    nextDelay = attempt < self.timing.retries.count ? self.timing.retries[attempt] : self.timing.environment
                }
            }
            guard self.generation == current else { return }
            self.operation = nil
            self.isTransitioning = false
            if targetsStillVisible, let actual = lastActual {
                if self.backend.retainPlan != nil {
                    var reduced = plan
                    for item in actual.bars.flatMap(\.items) {
                        if plan.applicationKeys.contains(item.bundle) {
                            reduced = reduced.excluding(.application(item.bundle), reason: "macOS did not hide this icon after repeated attempts. Its original setting was restored.")
                        }
                        if plan.systemItemIDs.contains(item.id) {
                            reduced = reduced.excluding(.system(item.id), reason: "macOS did not hide this icon after repeated attempts. Its original setting was restored.")
                        }
                    }
                    if reduced != plan {
                        do {
                            reduced = try self.backend.refinePlan?(baseline, reduced) ?? reduced
                            try self.keepEligiblePlan(reduced, baseline: baseline)
                        } catch {
                            self.report(self.isHidden, title: "Couldn’t restore excluded icons", message: error.localizedDescription)
                        }
                        return
                    }
                }
                if self.restoreVisibility(preservingIntent: false) {
                    self.report(self.isHidden, title: "Couldn’t verify icon hiding",
                        message: NativeMenuBarSnapshot.Failure.verification.localizedDescription)
                }
                return
            }
            // An unavailable AX tree is not evidence that hidden settings should
            // be undone. Keep the transaction; the next event can retry checking.
            self.trace("hidden check pending: keeping existing transaction")
            if self.checkRequested { self.startReconciliation(delay: self.timing.environment) }
        }
    }

    private func report(_ hidden: Bool, title: String, message: String?, identifier: String? = nil) {
        noticeIdentifier = identifier
        noticeTitle = menuBoxLocalized(title)
        onChange?(hidden, message)
    }

    @discardableResult
    private func finishEmptyPlan(_ plan: MenuBarSectionPlanner.Plan) -> Bool {
        guard plan.applicationKeys.isEmpty, plan.systemItemIDs.isEmpty, !plan.exclusions.isEmpty else { return false }
        wantsHidden = false
        isHidden = false
        isTransitioning = false
        operation = nil
        baseline = nil
        boundaryReference = nil
        appliedPlan = nil
        hiddenApplications = []
        hiddenSystemItems = []
        setMarkerHidden?(false)
        report(false, title: "No icons could be hidden", message: Self.partialMessage(plan),
               identifier: HidingNoticeIdentity.partial(plan))
        return true
    }

    private func keepEligiblePlan(_ plan: MenuBarSectionPlanner.Plan, baseline: NativeMenuBarSnapshot) throws {
        try backend.retainPlan?(baseline, plan)
        trace("excluded icons: " + plan.exclusions.map(\.identifier).sorted().joined(separator: ","))
        if finishEmptyPlan(plan) { return }
        appliedPlan = plan
        hiddenApplications = plan.applicationKeys
        hiddenSystemItems = plan.systemItemIDs
        startReconciliation(delay: timing.verification)
    }

    private static func applyVisibility(_ snapshot: NativeMenuBarSnapshot, _ plan: MenuBarSectionPlanner.Plan) throws {
        guard let journal = try visibilityJournal(snapshot, plan) else { return }
        let preferences = try NativeMenuBarPreferences()
        try NativeMenuBarRecovery.save(journal)
        try preferences.write(journal.written, replacing: journal.original)
        try NativeSystemMenuBarPreferences.apply(journal.systemChanges ?? [])
    }

    private static func stageExtension(_ snapshot: NativeMenuBarSnapshot, _ old: MenuBarSectionPlanner.Plan,
                                       _ new: MenuBarSectionPlanner.Plan) throws {
        if NativeMenuBarRecovery.hasPending {
            try NativeMenuBarRecovery.stageExtension(applications: new.applicationKeys.subtracting(old.applicationKeys),
                systemItems: new.systemItemIDs.subtracting(old.systemItemIDs), snapshot: snapshot)
        } else if let journal = try visibilityJournal(snapshot, new) {
            try NativeMenuBarRecovery.save(journal)
        }
    }

    private static func visibilityJournal(_ snapshot: NativeMenuBarSnapshot, _ plan: MenuBarSectionPlanner.Plan) throws -> NativeMenuBarRecovery.Journal? {
        let applications = plan.applicationKeys
        guard !applications.isEmpty || !plan.systemItemIDs.isEmpty else { return nil }
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
        return .init(original: document.data, written: data,
            previousAllowed: previous, addedSelfLocations: added, systemChanges: systemChanges, applications: applications)
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case NativeMenuBarSnapshot.Failure.incomplete, NativeMenuBarSnapshot.Failure.boundary,
             NativeMenuBarSnapshot.Failure.verification,
             MenuBarSectionPlanner.Failure.incompleteSnapshot,
             MenuBarSectionPlanner.Failure.missingOrAmbiguousControls,
             MenuBarSectionPlanner.Failure.invalidItemGeometry,
             MenuBarSectionPlanner.Failure.ambiguousGeometry,
             NativeMenuBarPreferences.Failure.missing,
             NativeMenuBarPreferences.Failure.concurrentChange, NativeSystemMenuBarPreferences.Failure.concurrentChange:
            return true
        default: return false
        }
    }

    @discardableResult
    func show() -> Bool {
        trace("show requested")
        reportedRestoreFailure = false
        return restoreVisibility(preservingIntent: false)
    }

    @MainActor func prepareMenuPlacementRecovery() async throws {
        try await ensureHelper()
    }

    /// A short lease for generating a menu. The rest of the transaction and the
    /// marker stay hidden. Focus/layout notifications wait until the lease ends.
    func beginTemporaryReveal(_ bundle: String) throws -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wantsHidden, isHidden, !isSuspended, temporaryReveal == nil,
              hiddenApplications.contains(bundle), let baseline, let reveal = backend.temporarilyReveal else {
            throw NativeMenuBarSnapshot.Failure.incomplete
        }
        generation = UUID()
        operation?.cancel()
        operation = nil
        isTransitioning = false
        let token = UUID()
        temporaryReveal = (token, bundle)
        do { try reveal(bundle, baseline) }
        catch { endTemporaryReveal(token); throw error }
        trace("temporary menu reveal: " + bundle)
        return token
    }

    func temporaryRevealIsReady(_ token: UUID) throws -> Bool {
        guard let lease = temporaryReveal, lease.token == token,
              let baseline, let plan = appliedPlan else { throw CancellationError() }
        // The selected app is protected by the same visibility/order checks as
        // right-side icons. All other selected apps and system items stay hidden.
        return try backend.capture(true).excluding(plan.exclusions).hiddenState(plan.applicationKeys.subtracting([lease.bundle]),
            comparedTo: baseline.excluding(plan.exclusions), systemItems: plan.systemItemIDs) == .hidden
    }

    func endTemporaryReveal(_ token: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard temporaryReveal?.token == token else { return }
        let bundle = temporaryReveal!.bundle
        temporaryReveal = nil
        guard wantsHidden, let baseline, let plan = appliedPlan else { return }
        do {
            try backend.reapply(baseline, plan)
            trace("temporary menu rehidden: " + bundle)
        } catch {
            trace("temporary menu rehide failed: " + error.localizedDescription)
            report(isHidden, title: "Couldn’t apply menu bar settings", message: error.localizedDescription)
        }
        if !isSuspended { startReconciliation(delay: timing.verification) }
    }

    @discardableResult
    private func restoreVisibility(preservingIntent: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        operation?.cancel()
        operation = nil
        temporaryReveal = nil
        awaitingStatusItemRepair = false
        if !preservingIntent { wantsHidden = false }
        isTransitioning = false
        setMarkerHidden?(false)
        do {
            try backend.restore()
            let needsVerification = baseline != nil || backend.hasPendingRestore?() == true
            isHidden = false
            if needsVerification {
                isRestoring = true
                hiddenApplications.formUnion(backend.pendingApplications?() ?? [])
                if !isSuspended { startRestoration() }
            } else {
                finishRestoration()
            }
            return true
        } catch {
            isRestoring = true
            report(isHidden, title: "Couldn’t restore menu bar settings",
                   message: String(format: menuBoxLocalized("Could not restore the menu bar: %@"), error.localizedDescription))
            return false
        }
    }

    private func finishRestoration() {
        isRestoring = false
        reportedRestoreFailure = false
        isTransitioning = false
        operation = nil
        baseline = nil
        boundaryReference = nil
        appliedPlan = nil
        checkRequested = false
        hiddenApplications = []
        hiddenSystemItems = []
        onChange?(false, nil)
    }

    private func startRestoration() {
        guard isRestoring, !isSuspended else { return }
        isTransitioning = true
        let current = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastError: Error = NativeMenuBarSnapshot.Failure.restorationPending
            for attempt in 0...self.timing.retries.count {
                do {
                    let delay = attempt == 0 ? self.timing.verification : self.timing.retries[attempt - 1]
                    try await Task.sleep(nanoseconds: delay)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    try self.backend.restore()
                    if let baseline = self.baseline, !self.backend.settingsRestoreIsAuthoritative {
                        let actual = try self.backend.capture(false)
                        // A terminated app cannot republish an icon. Live backends
                        // resolve journal owners to currently running applications.
                        let applications = self.backend.pendingApplications?() ?? self.hiddenApplications
                        try actual.verifyRestored(applications, systemItems: self.hiddenSystemItems, comparedTo: baseline)
                    }
                    try self.backend.finishRestore?()
                    self.trace("show verified: " + self.hiddenApplications.sorted().joined(separator: ","))
                    self.finishRestoration()
                    if self.wantsHidden { self.startAttempt(delay: self.timing.initial) }
                    return
                } catch {
                    guard !Task.isCancelled, self.generation == current else { return }
                    lastError = error
                    self.trace("show verification pending (attempt \(attempt + 1)): \(error)")
                }
            }
            guard self.generation == current, !Task.isCancelled else { return }
            self.operation = nil
            self.isTransitioning = false
            if !self.reportedRestoreFailure {
                self.reportedRestoreFailure = true
                self.report(false, title: "Couldn’t restore menu bar settings", message: lastError.localizedDescription)
            }
        }
    }

    func verifyAfterFocusChange() {
        guard isHidden || isRestoring else { return }
        environmentChanged(reason: "focus")
    }

    func environmentChanged(reason: String = "environment") {
        if isRestoring {
            if operation == nil, !isSuspended { startRestoration() }
            return
        }
        guard wantsHidden, !isSuspended else { return }
        trace("check requested: " + reason)
        if operation != nil || temporaryReveal != nil {
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
        if let lease = temporaryReveal { endTemporaryReveal(lease.token) }
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
        if isRestoring {
            startRestoration()
        } else if wasSuspended, wantsHidden, baseline != nil {
            startReconciliation(delay: 0)
        } else {
            environmentChanged(reason: reason)
        }
    }

    func stop() {
        trace("stop requested")
        _ = show()
        generation = UUID()
        operation?.cancel()
        operation = nil
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
        guard let executable = Bundle.main.executableURL else { throw HelperFailure.unavailable }
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
                    throw HelperFailure.unavailable
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            guard response == "READY\n", process.isRunning else { throw HelperFailure.unavailable }
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
