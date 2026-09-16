import AppKit
import XCTest
@testable import MenuBox

@MainActor
final class NativeMenuBarHidingTests: XCTestCase {
    private final class MenuBar {
        var applicationsHidden = false
        var markerHidden = false
        var unavailableCaptures = 0
        var writes = 0
        var restores = 0
        var checks = 0
        var errors: [String] = []
        var denied = false
        var includeSecond = false
        var temporaryApp: String?

        func snapshot() throws -> NativeMenuBarSnapshot {
            checks += 1
            if denied { throw NativeMenuBarSnapshot.Failure.permission }
            if unavailableCaptures > 0 {
                unavailableCaptures -= 1
                throw NativeMenuBarSnapshot.Failure.incomplete
            }
            let own = NativeMenuBarPreferences.ownBundle
            var layout: [(String, String, CGFloat)] = [
                ("left", "left", 10), ("MenuBox.marker", own, 60),
                ("MenuBox.main", own, 100), ("right", "right", 140),
                ("focus", "com.apple.MenuBarAgent", 180)
            ]
            if includeSecond { layout.append(("second", "second", 35)) }
            let items = layout.filter { id, _, _ in
                !(applicationsHidden && ["left", "second"].contains(id) && id != temporaryApp) &&
                    !(markerHidden && id == "MenuBox.marker")
            }.map { id, bundle, x in
                NativeMenuBarSnapshot.Item(id: id, bundle: bundle,
                    frame: CGRect(x: x, y: 0, width: 20, height: 24), identifier: id)
            }
            return .init(bars: [.init(frame: CGRect(x: 0, y: 0, width: 250, height: 24), items: items)],
                         executables: [:])
        }

        func controller(initial: UInt64 = 1_000_000, retries: [UInt64] = [1_000_000, 2_000_000, 3_000_000]) -> NativeMenuBarHiding {
            let backend = NativeMenuBarHiding.Backend(capture: { _ in try self.snapshot() }, apply: { _, plan in
                XCTAssertEqual(plan.applicationKeys, self.includeSecond ? ["left", "second"] : ["left"])
                self.writes += 1
                self.applicationsHidden = true
            }, restore: { self.restores += 1; self.applicationsHidden = false; self.temporaryApp = nil }, reapply: { _, _ in
                self.writes += 1
                self.applicationsHidden = true
                self.temporaryApp = nil
            }, temporarilyReveal: { bundle, _ in self.temporaryApp = bundle }, prepare: {}, log: { _ in })
            let hiding = NativeMenuBarHiding(backend: backend,
                timing: .init(initial: initial, environment: 2_000_000, verification: 1_000_000, retries: retries))
            hiding.setMarkerHidden = { self.markerHidden = $0 }
            hiding.onChange = { _, error in if let error { self.errors.append(error) } }
            return hiding
        }
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("State did not settle", file: file, line: line)
    }

    func testWakeRestoresHiddenIntentAfterTransientMissingMenuBar() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        hiding.suspend()
        XCTAssertTrue(hiding.wantsHidden)
        XCTAssertTrue(hiding.isHidden)
        XCTAssertTrue(bar.applicationsHidden)
        let restores = bar.restores
        bar.unavailableCaptures = 2
        hiding.resume()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertTrue(bar.markerHidden)
        XCTAssertTrue(bar.applicationsHidden)
        XCTAssertTrue(bar.errors.isEmpty)
        XCTAssertEqual(bar.restores, restores)
        XCTAssertEqual(bar.writes, 1)
    }

    func testSleepDuringInitialTransitionPreservesRequest() async throws {
        let bar = MenuBar(), hiding = bar.controller(initial: 50_000_000)
        defer { hiding.stop() }
        hiding.hide()
        hiding.suspend()
        XCTAssertTrue(hiding.wantsHidden)
        hiding.resume()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, 1)
    }

    func testExplicitRevealCancelsWakeAndPendingRetries() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        hiding.suspend()
        bar.unavailableCaptures = 20
        hiding.resume()
        XCTAssertTrue(hiding.show())
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(hiding.wantsHidden)
        XCTAssertFalse(hiding.isHidden)
        XCTAssertFalse(bar.markerHidden)
        XCTAssertEqual(bar.writes, 1)
        hiding.resume()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(hiding.isTransitioning)
    }

    func testExhaustedLayoutRetriesCanRecoverOnNextWake() async throws {
        let bar = MenuBar(), hiding = bar.controller(retries: [1_000_000])
        defer { hiding.stop() }
        bar.unavailableCaptures = 10
        hiding.hide()
        try await eventually { !bar.errors.isEmpty }
        XCTAssertTrue(hiding.wantsHidden)
        XCTAssertFalse(hiding.isTransitioning)
        XCTAssertEqual(bar.writes, 0)
        bar.unavailableCaptures = 0
        hiding.resume()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
    }

    func testFocusVerificationFailureReappliesInsteadOfForgettingIntent() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        bar.applicationsHidden = false
        hiding.verifyAfterFocusChange()
        try await eventually { hiding.isHidden && bar.writes == 2 }
        XCTAssertTrue(hiding.wantsHidden)
        XCTAssertTrue(bar.markerHidden)
    }

    func testEnvironmentChangesWhileReapplyingDoNotDropIntent() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        hiding.environmentChanged()
        hiding.environmentChanged()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, 1)
    }

    func testPermissionFailureDoesNotCauseRepeatedHidingAttempts() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        bar.denied = true
        hiding.hide()
        try await eventually { !bar.errors.isEmpty }
        XCTAssertFalse(hiding.wantsHidden)
        XCTAssertFalse(hiding.isTransitioning)
        XCTAssertEqual(bar.writes, 0)
        XCTAssertEqual(bar.errors.count, 1)
    }
    func testRepeatedWakeAndEnvironmentEventsNeverRevealEstablishedTransaction() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let restores = bar.restores
        hiding.suspend()
        hiding.suspend()
        bar.unavailableCaptures = 2
        for _ in 0..<5 {
            hiding.resume()
            hiding.environmentChanged()
        }
        try await eventually { !hiding.isTransitioning }
        XCTAssertEqual(bar.restores, restores)
        XCTAssertEqual(bar.writes, 1)
        XCTAssertTrue(bar.applicationsHidden)
        XCTAssertTrue(bar.markerHidden)
    }

    func testSleepAfterWriteBeforeVerificationKeepsAppliedTransaction() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { bar.writes == 1 }
        let restores = bar.restores
        hiding.suspend()
        XCTAssertTrue(bar.applicationsHidden)
        XCTAssertTrue(bar.markerHidden)
        hiding.resume()
        try await eventually { !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, 1)
        XCTAssertEqual(bar.restores, restores)
    }

    func testExhaustedWakeObservationsKeepHiddenSettingsUntilNextEvent() async throws {
        let bar = MenuBar(), hiding = bar.controller(retries: [1_000_000])
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let restores = bar.restores
        hiding.suspend()
        bar.unavailableCaptures = 20
        hiding.resume()
        try await eventually { !hiding.isTransitioning }
        XCTAssertTrue(bar.applicationsHidden)
        XCTAssertTrue(bar.markerHidden)
        XCTAssertEqual(bar.restores, restores)
        bar.unavailableCaptures = 0
        hiding.environmentChanged()
        try await eventually { !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, 1)
    }

    func testWakeReappliesResetFlagsWithoutReveal() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let restores = bar.restores
        hiding.suspend()
        bar.applicationsHidden = false
        hiding.resume()
        try await eventually { !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, 2)
        XCTAssertEqual(bar.restores, restores)
        XCTAssertTrue(bar.applicationsHidden)
    }

    func testTemporaryMenuRevealKeepsOtherAppsMarkerAndHiddenIntent() async throws {
        let bar = MenuBar(); bar.includeSecond = true
        let hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let restores = bar.restores
        let lease = try hiding.beginTemporaryReveal("left")
        XCTAssertTrue(try hiding.temporaryRevealIsReady(lease))
        for _ in 0..<5 { hiding.environmentChanged(); hiding.verifyAfterFocusChange() }
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertEqual(bar.temporaryApp, "left")
        XCTAssertTrue(bar.markerHidden)
        XCTAssertTrue(hiding.wantsHidden)
        XCTAssertEqual(hiding.hiddenApplications, ["left", "second"])
        let bundles = Set(try bar.snapshot().bars.flatMap(\.items).map(\.bundle))
        XCTAssertTrue(bundles.contains("left"))
        XCTAssertFalse(bundles.contains("second"))
        hiding.endTemporaryReveal(lease)
        try await eventually { !hiding.isTransitioning }
        XCTAssertNil(bar.temporaryApp)
        XCTAssertEqual(bar.restores, restores)
        XCTAssertTrue(bar.errors.isEmpty)
    }

    func testExplicitRevealInvalidatesMenuLeaseSoLateCleanupCannotHideAgain() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let lease = try hiding.beginTemporaryReveal("left")
        XCTAssertTrue(hiding.show())
        let writes = bar.writes
        hiding.endTemporaryReveal(lease)
        XCTAssertEqual(bar.writes, writes)
        XCTAssertFalse(hiding.wantsHidden)
        XCTAssertFalse(bar.applicationsHidden)
    }

    func testSleepRehidesTemporaryAppBeforeResumingExistingTransaction() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        let lease = try hiding.beginTemporaryReveal("left")
        hiding.suspend()
        XCTAssertNil(bar.temporaryApp)
        XCTAssertTrue(bar.applicationsHidden)
        XCTAssertTrue(bar.markerHidden)
        let writes = bar.writes
        hiding.endTemporaryReveal(lease)
        hiding.resume()
        try await eventually { !hiding.isTransitioning }
        XCTAssertEqual(bar.writes, writes)
        XCTAssertTrue(hiding.wantsHidden)
    }

    func testMenuLeaseRejectsUnselectedAppAndConcurrentLease() async throws {
        let bar = MenuBar(), hiding = bar.controller()
        defer { hiding.stop() }
        hiding.hide()
        try await eventually { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertThrowsError(try hiding.beginTemporaryReveal("right"))
        let lease = try hiding.beginTemporaryReveal("left")
        XCTAssertThrowsError(try hiding.beginTemporaryReveal("left"))
        hiding.endTemporaryReveal(lease)
    }

}
