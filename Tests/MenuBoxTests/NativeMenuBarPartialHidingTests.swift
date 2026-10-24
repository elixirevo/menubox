// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.
import AppKit
import MacAppCore
import XCTest
@testable import MenuBox

final class NativeMenuBarPartialHidingTests: XCTestCase {
    private func document(_ records: [(String, Bool, [String])]) throws -> NativeMenuBarPreferences.Document {
        func location(_ key: String) -> [String: Any] { ["bundle": ["_0": key]] }
        let entries: [Any] = records.flatMap { key, allowed, items in
            [location(key), ["location": location(key), "isAllowed": allowed, "menuItemLocations": items.map(location)]]
        }
        return try NativeMenuBarPreferences.decode(PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0))
    }

    private func snapshot(hidden: Set<String> = [], markerHidden: Bool = false) -> NativeMenuBarSnapshot {
        let layout: [(String, String, CGFloat)] = [("good", "good", 10), ("bad", "bad", 40),
            ("MenuBox.marker", NativeMenuBarPreferences.ownBundle, 90),
            ("MenuBox.main", NativeMenuBarPreferences.ownBundle, 120), ("right", "right", 160)]
        let items = layout.filter { !hidden.contains($0.1) && !(markerHidden && $0.0 == "MenuBox.marker") }.map {
            NativeMenuBarSnapshot.Item(id: $0.0, bundle: $0.1,
                frame: CGRect(x: $0.2, y: 0, width: 20, height: 24), identifier: $0.0)
        }
        return .init(bars: [.init(frame: CGRect(x: 0, y: 0, width: 240, height: 24), items: items)], executables: [:])
    }

    func testMissingDisabledAmbiguousAndSharedOwnersOnlyExcludeAffectedApps() throws {
        let badRecords: [[(String, Bool, [String])]] = [[], [("bad", false, ["bad"])],
            [("owner1", true, ["bad"]), ("owner2", true, ["bad"])], [("bad", true, ["bad", "right"])]]
        for bad in badRecords {
            let doc = try document([("good", true, ["good"])] + bad)
            let snapshot = snapshot()
            let plan = try NativeMenuBarHiding.eligiblePlan(snapshot, snapshot.plan(), document: doc) { _ in }
            XCTAssertEqual(plan.applicationKeys, ["good"])
            XCTAssertEqual(plan.exclusions.map(\.identifier), ["bad"])
            XCTAssertEqual(doc.records["good"]?.allowed, true, "Preflight must not write preferences")
        }
    }

    func testRemovingOneHelperAlsoProtectsSiblingWithSameSetting() throws {
        let doc = try document([("owner", true, ["good", "bad"])])
        let snapshot = snapshot()
        let proposed = try snapshot.plan().excluding(.application("bad"), reason: "Excluded")
        let plan = try NativeMenuBarHiding.eligiblePlan(snapshot, proposed, document: doc) { _ in }
        XCTAssertTrue(plan.applicationKeys.isEmpty)
        XCTAssertEqual(Set(plan.exclusions.map(\.identifier)), ["bad", "good"])
    }

    func testUnsupportedSystemDoesNotBlockApp() throws {
        let snapshot = snapshot()
        let requested = MenuBarSectionPlanner.Plan(applicationKeys: ["good"], protectedItemsByDisplay: [:], systemItemIDs: ["unknown"])
        let plan = try NativeMenuBarHiding.eligiblePlan(snapshot, requested,
            document: document([("good", true, ["good"])])) { throw NativeSystemMenuBarPreferences.Failure.unsupported($0) }
        XCTAssertEqual(plan.applicationKeys, ["good"])
        XCTAssertTrue(plan.systemItemIDs.isEmpty)
        XCTAssertEqual(plan.exclusions.map(\.identifier), ["unknown"])
    }

    func testRecoverySkipsRemovedRecordsWithoutResurrectingThem() throws {
        let original = try document([("good", true, ["good"]), ("removed", true, ["removed"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["good": false, "removed": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["good": true, "removed": true])
        let current = try document([("good", false, ["good"]), ("right", false, ["right"])])
        XCTAssertFalse(NativeMenuBarRecovery.restoredSettingsMatch(journal, current: current))
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: current))
        XCTAssertNil(restored.records["removed"])
        XCTAssertEqual(restored.records["good"]?.allowed, true)
        XCTAssertEqual(restored.records["right"]?.allowed, false)
        XCTAssertTrue(NativeMenuBarRecovery.restoredSettingsMatch(journal, current: restored))
    }

    func testNarrowedJournalRestoresOnlyRemainingAppsAndPreservesOtherEdits() throws {
        let original = try document([("good", true, ["good"]), ("bad", true, ["bad"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["good": false, "bad": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
            previousAllowed: ["good": true, "bad": true], applications: ["good", "bad"])
        let reduced = try XCTUnwrap(NativeMenuBarRecovery.retaining(journal, keys: ["good"], systemItems: [], applications: ["good"]))
        XCTAssertEqual(reduced.previousAllowed, ["good": true])
        XCTAssertEqual(reduced.applications, ["good"])
        let current = try document([("good", false, ["good"]), ("bad", true, ["bad"]), ("right", false, ["right"])])
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(reduced, current: current))
        XCTAssertEqual(restored.records["good"]?.allowed, true)
        XCTAssertEqual(restored.records["bad"]?.allowed, true)
        XCTAssertEqual(restored.records["right"]?.allowed, false)
        XCTAssertNil(try NativeMenuBarRecovery.retaining(journal, keys: [], systemItems: [], applications: []))
    }

    @MainActor
    func testNonresponsiveAppIsRestoredAloneWhileOtherAppStaysHidden() async throws {
        var markerHidden = false, hidden = Set<String>(), restores = 0, retained = 0
        var notices: [String] = []
        let backend = NativeMenuBarHiding.Backend(capture: { _ in self.snapshot(hidden: hidden, markerHidden: markerHidden) },
            apply: { _, _ in hidden = ["good"] }, restore: { restores += 1; hidden = [] },
            reapply: { _, _ in hidden = ["good"] }, retainPlan: { _, plan in
                retained += 1
                XCTAssertEqual(plan.applicationKeys, ["good"])
                hidden = plan.applicationKeys
            }, prepare: {}, log: { _ in })
        let hiding = NativeMenuBarHiding(backend: backend, timing: .init(environment: 1_000_000, verification: 1_000_000, retries: [1_000_000]))
        hiding.setMarkerHidden = { markerHidden = $0 }
        hiding.onChange = { _, error in if let error { notices.append(error) } }
        defer { hiding.stop() }
        hiding.hide()
        try await settle { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertEqual(hiding.hiddenApplications, ["good"])
        XCTAssertEqual(hidden, ["good"])
        XCTAssertEqual(restores, 1, "Only the initial stale-journal check may restore all apps")
        XCTAssertEqual(retained, 1)
        XCTAssertTrue(notices.last?.contains("bad") == true)
        hiding.environmentChanged()
        try await settle { !hiding.isTransitioning }
        XCTAssertEqual(retained, 1, "Excluded icons must not be automatically re-added")
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testSettingsVerifiedRecoveryDoesNotWaitForMissingIconHosts() async throws {
        var pending = true, writes = 0, markerHidden = false, hidden = Set<String>()
        let backend = NativeMenuBarHiding.Backend(capture: { _ in self.snapshot(hidden: hidden, markerHidden: markerHidden) },
            apply: { _, plan in writes += 1; hidden = plan.applicationKeys }, restore: {}, reapply: { _, _ in },
            finishRestore: { pending = false }, pendingApplications: { ["gone-app"] }, hasPendingRestore: { pending },
            settingsRestoreIsAuthoritative: true, prepare: {}, log: { _ in })
        let hiding = NativeMenuBarHiding(backend: backend, timing: .init(verification: 1_000_000, retries: [1_000_000]))
        hiding.setMarkerHidden = { markerHidden = $0 }
        defer { hiding.stop() }
        hiding.hide()
        try await settle { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertFalse(pending)
        XCTAssertFalse(hiding.isRestoring)
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testAllNonresponsiveIconsLeaveMarkerVisibleAndDoNotReportHidden() async throws {
        var markerHidden = false, retained = 0
        var message: String?
        let backend = NativeMenuBarHiding.Backend(capture: { _ in self.snapshot(markerHidden: markerHidden) },
            apply: { _, _ in }, restore: {}, reapply: { _, _ in }, retainPlan: { _, plan in
                retained += 1
                XCTAssertTrue(plan.applicationKeys.isEmpty)
            }, prepare: {}, log: { _ in })
        let hiding = NativeMenuBarHiding(backend: backend, timing: .init(verification: 1_000_000, retries: [1_000_000]))
        hiding.setMarkerHidden = { markerHidden = $0 }
        hiding.onChange = { _, error in if let error { message = error } }
        defer { hiding.stop() }
        hiding.hide()
        try await settle { message != nil && !hiding.isTransitioning }
        XCTAssertFalse(hiding.isHidden)
        XCTAssertFalse(markerHidden)
        XCTAssertFalse(hiding.wantsHidden)
        XCTAssertEqual(retained, 1)
        XCTAssertTrue(message?.contains("bad") == true)
        XCTAssertTrue(message?.contains("good") == true)
        XCTAssertEqual(hiding.noticeTitle, menuBoxLocalized("No icons could be hidden"))
    }

    @MainActor
    func testActualRestoreWriteFailureRetainsJournalAndReportsActualCause() async throws {
        var allowRestore = false, pending = true, writes = 0, markerHidden = false, hidden = Set<String>()
        var message: String?
        let backend = NativeMenuBarHiding.Backend(capture: { _ in self.snapshot(hidden: hidden, markerHidden: markerHidden) },
            apply: { _, plan in writes += 1; hidden = plan.applicationKeys },
            restore: { if !allowRestore { throw NativeMenuBarPreferences.Failure.write } }, reapply: { _, _ in },
            finishRestore: { pending = false }, hasPendingRestore: { pending }, settingsRestoreIsAuthoritative: true,
            prepare: {}, log: { _ in })
        let hiding = NativeMenuBarHiding(backend: backend, timing: .init(verification: 1_000_000, retries: [1_000_000]))
        hiding.setMarkerHidden = { markerHidden = $0 }
        hiding.onChange = { _, error in if let error { message = error } }
        defer { hiding.stop() }
        hiding.hide()
        XCTAssertTrue(hiding.isRestoring)
        XCTAssertTrue(pending)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(message?.contains(NativeMenuBarPreferences.Failure.write.localizedDescription) == true)
        XCTAssertEqual(hiding.noticeTitle, menuBoxLocalized("Couldn’t restore menu bar settings"))
        allowRestore = true
        hiding.hide()
        try await settle { hiding.isHidden && !hiding.isTransitioning }
        XCTAssertFalse(pending)
        XCTAssertEqual(writes, 1)
    }

    func testDamagedJournalIsDistinguishedFromMissingPermissions() {
        XCTAssertThrowsError(try NativeMenuBarRecovery.decodedJournal(Data("invalid".utf8))) {
            guard case NativeMenuBarRecovery.Failure.damagedRecord = $0 else { return XCTFail("Wrong recovery cause: \($0)") }
        }
    }

    @MainActor
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Hiding did not settle")
    }
}
