// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import CoreGraphics
import XCTest
@testable import MenuBox

final class NativeMenuBarSnapshotTests: XCTestCase {
    func testRestoreRequiresTargetsOnEveryRemainingDisplay() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(-200), bar(0)], executables: [:])
        var missing = bar(0)
        missing.items.removeAll { $0.bundle == "one" }
        let partial = NativeMenuBarSnapshot(bars: [bar(-200), missing], executables: [:])
        XCTAssertThrowsError(try partial.verifyRestored(["one", "two"], systemItems: [], comparedTo: before))
        XCTAssertNoThrow(try before.verifyRestored(["one", "two"], systemItems: [], comparedTo: before))
        // A disconnected display is not a forever-pending restore.
        let disconnected = NativeMenuBarSnapshot(bars: [bar(-200)], executables: [:])
        XCTAssertNoThrow(try disconnected.verifyRestored(["one", "two"], systemItems: [], comparedTo: before))
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [], executables: [:])
            .verifyRestored(["one"], systemItems: [], comparedTo: before))
    }

    func testStandaloneAppleAppsUseCommonRouteWithoutBeingListed() throws {
        for bundle in ["com.apple.Passwords.MenuBarExtra", "com.apple.FutureApp.MenuBarExtra", "org.example.NewApp"] {
            var visible = bar(0)
            visible.items[0] = item(bundle + ":0", bundle, 10)
            let plan = try NativeMenuBarSnapshot(bars: [visible], executables: [:]).plan()
            XCTAssertTrue(plan.applicationKeys.contains(bundle))
            XCTAssertTrue(plan.systemItemIDs.isEmpty)
        }
    }

    func testKnownAdapterUsesCommonRecordWhenAvailableButSharedHostsNeverDo() throws {
        let input = NativeSystemMenuBarPreferences.Setting.inputMenu.itemID
        var visible = bar(0)
        visible.items[0] = item(input, "com.apple.TextInputMenuAgent", 10)
        let fallback = try NativeMenuBarSnapshot(bars: [visible], executables: [:]).plan()
        XCTAssertEqual(fallback.systemItemIDs, [input])
        let common = try NativeMenuBarSnapshot(bars: [visible], executables: [:],
            applicationControlBundles: ["com.apple.TextInputMenuAgent"]).plan()
        XCTAssertTrue(common.systemItemIDs.isEmpty)
        XCTAssertTrue(common.applicationKeys.contains("com.apple.TextInputMenuAgent"))
        visible.items[0] = item("unknown-control", "com.apple.MenuBarAgent", 10)
        let shared = try NativeMenuBarSnapshot(bars: [visible], executables: [:],
            applicationControlBundles: ["com.apple.MenuBarAgent"]).plan()
        XCTAssertEqual(shared.systemItemIDs, ["unknown-control"])
        XCTAssertFalse(shared.applicationKeys.contains("com.apple.MenuBarAgent"))
    }

    func testAppleAppArrivingWhileHiddenUsesCommonRouteAndProtectsOtherDisplays() throws {
        let bundle = "com.apple.Passwords.MenuBarExtra"
        let before = NativeMenuBarSnapshot(bars: [bar(-200), bar(0)], executables: [:])
        var left = hiddenBar(bar(-200)), right = hiddenBar(bar(0))
        left.items.append(item(bundle + ":0", bundle, -170))
        let update = try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        XCTAssertTrue(update.plan.applicationKeys.contains(bundle))
        XCTAssertTrue(update.plan.systemItemIDs.isEmpty)
        right.items.append(item(bundle + ":0", bundle, 170))
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan()))
        let protectedBefore = NativeMenuBarSnapshot(bars: [bar(-200), barWithAppleRight(bundle)], executables: [:])
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: protectedBefore, boundaryReference: protectedBefore, plan: protectedBefore.plan()))
    }

    private func barWithAppleRight(_ bundle: String) -> NativeMenuBarSnapshot.Bar {
        var value = bar(0)
        value.items.append(item(bundle + ":0", bundle, 170))
        return value
    }

    func testCapturesOnlyMenuBarsOnConnectedDisplays() {
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        CGRect(x: -2560, y: -323, width: 2560, height: 1440)]
        XCTAssertTrue(NativeMenuBarSnapshot.isMenuBar(CGRect(x: 0, y: 0, width: 1728, height: 33), on: displays))
        XCTAssertTrue(NativeMenuBarSnapshot.isMenuBar(CGRect(x: -2560, y: -323, width: 2560, height: 30), on: displays))
        for frame in [CGRect(x: -5120, y: -323, width: 2560, height: 30),
                      CGRect(x: 1200, y: 33, width: 400, height: 600),
                      CGRect(x: 0, y: 0, width: 1728, height: 700),
                      CGRect(x: 0, y: 200, width: 1728, height: 33)] {
            XCTAssertFalse(NativeMenuBarSnapshot.isMenuBar(frame, on: displays))
        }
    }

    private let own = NativeMenuBarPreferences.ownBundle
    private func item(_ id: String, _ bundle: String, _ x: CGFloat) -> NativeMenuBarSnapshot.Item {
        .init(id: id, bundle: bundle, frame: CGRect(x: x, y: 0, width: 20, height: 24), identifier: id)
    }
    private func bar(_ x: CGFloat, overflow: Bool = false) -> NativeMenuBarSnapshot.Bar {
        .init(frame: CGRect(x: x, y: 0, width: 200, height: 24), items: [
            item("one", "one", x + 10), item("two", "two", x + (overflow ? 10 : 35)),
            item("MenuBox.marker", own, x + 70), item("MenuBox.main", own, x + 100),
            item("focus", "com.apple.MenuBarAgent", x + 140)
        ])
    }

    func testOverflowReplicaUsesReferenceOnlyWhenIdentitiesAndSidesAgree() throws {
        let snapshot = NativeMenuBarSnapshot(bars: [bar(-200), bar(0, overflow: true)], executables: [:])
        XCTAssertEqual(try snapshot.plan().applicationKeys, ["one", "two"])
    }

    func testDifferentRightSideItemsAndOffsetsDoNotBreakControlResolutionOrPlan() throws {
        let reference = bar(-200)
        var replica = bar(0)
        // Real three-display failure: the inactive replica omits identifiers,
        // and extra right-side controls push MenuBox farther from the edge.
        replica.items[2] = .init(id: "own:0", bundle: own,
            frame: CGRect(x: 60, y: 0, width: 20, height: 24), identifier: "")
        replica.items[3] = .init(id: "own:1", bundle: own,
            frame: CGRect(x: 90, y: 0, width: 20, height: 24), identifier: "")
        replica.items.append(item("right-only", "right-only", 170))
        let bars = try NativeMenuBarSnapshot.resolveControls([reference, replica], markerHidden: false)
        let snapshot = NativeMenuBarSnapshot(bars: bars, executables: [:])
        let plan = try snapshot.plan()
        XCTAssertEqual(plan.applicationKeys, ["one", "two"])
        XCTAssertTrue(plan.protectedItemsByDisplay[replica.id]!.contains("right-only"))
        let hidden = bars.map { bar in
            NativeMenuBarSnapshot.Bar(frame: bar.frame, items: bar.items.filter {
                !plan.applicationKeys.contains($0.bundle) && $0.id != "MenuBox.marker"
            })
        }
        XCTAssertNoThrow(try NativeMenuBarSnapshot(bars: hidden, executables: [:])
            .verifyHidden(plan.applicationKeys, comparedTo: snapshot, markerHidden: true))
    }

    func testControlResolutionRejectsMissingOverlappingOrContradictoryReplicas() {
        let reference = bar(-200)
        var missing = bar(0)
        missing.items.removeAll { $0.id == "MenuBox.main" }
        var overlap = bar(0)
        overlap.items[3] = item("MenuBox.main", own, 75)
        var reversed = bar(0)
        reversed.items[2] = item("MenuBox.main", own, 70)
        reversed.items[3] = item("MenuBox.marker", own, 100)
        for invalid in [missing, overlap, reversed] {
            XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([reference, invalid], markerHidden: false))
        }
    }

    func testSingleKnownControlResolvesOtherControlAcrossDisplaysAfterHostRestart() throws {
        for knownID in ["MenuBox.marker", "MenuBox.main"] {
            var reference = bar(-200), replica = bar(0)
            reference.items = reference.items.map { entry in
                guard entry.bundle == own, entry.identifier != knownID else { return entry }
                return .init(id: entry.id, bundle: own, frame: entry.frame, identifier: "")
            }
            replica.items = replica.items.map { entry in
                guard entry.bundle == own else { return entry }
                return .init(id: entry.id, bundle: own, frame: entry.frame, identifier: "")
            }
            let resolved = try NativeMenuBarSnapshot.resolveControls([reference, replica], markerHidden: false)
            for display in resolved {
                XCTAssertEqual(display.items.filter { $0.bundle == own }.map(\.id), ["MenuBox.marker", "MenuBox.main"])
            }
            XCTAssertEqual(try NativeMenuBarSnapshot(bars: resolved, executables: [:]).plan().applicationKeys, ["one", "two"])
        }
    }

    func testPartialControlIdentityDoesNotAssumeMarkerIsLeft() throws {
        var reference = bar(0)
        reference.items[2] = .init(id: "unknown", bundle: own, frame: reference.items[2].frame, identifier: "")
        reference.items[3] = item("MenuBox.marker", own, 100)
        let resolved = try NativeMenuBarSnapshot.resolveControls([reference], markerHidden: false)
        XCTAssertEqual(resolved[0].items.filter { $0.bundle == own }.map(\.id), ["MenuBox.main", "MenuBox.marker"])
    }

    func testMissingAllIdentifiersAndContradictoryPartialIdentitiesRemainUnresolved() {
        var unknown = bar(0)
        unknown.items = unknown.items.map { entry in
            guard entry.bundle == own else { return entry }
            return .init(id: entry.id, bundle: own, frame: entry.frame, identifier: "")
        }
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([unknown], markerHidden: false))
        var partial = unknown
        partial.items[2] = item("MenuBox.marker", own, 70)
        var conflict = unknown
        conflict.items[2] = item("MenuBox.main", own, 70)
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([partial, conflict], markerHidden: false))
        var duplicate = partial
        duplicate.items[3] = item("MenuBox.marker", own, 100)
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([duplicate], markerHidden: false))
        partial.items[3] = .init(id: "overlap", bundle: own,
            frame: CGRect(x: 75, y: 0, width: 20, height: 24), identifier: "")
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([partial], markerHidden: false))
        var hidden = hiddenBar(bar(0))
        hidden.items[0] = .init(id: "unknown", bundle: own, frame: hidden.items[0].frame, identifier: "")
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([hidden], markerHidden: true),
            "A blank remaining host must not be assumed to be the Box")
    }

    func testIdentifiedCollapsedMarkerResolvesBlankBoxButNotMissingBox() throws {
        var captured = bar(0)
        captured.items[2] = .init(id: "marker", bundle: own,
            frame: CGRect(x: 70, y: 0, width: 16, height: 24), identifier: "MenuBox.marker")
        captured.items[3] = .init(id: "box", bundle: own, frame: captured.items[3].frame, identifier: "")
        let resolved = try NativeMenuBarSnapshot.resolveControls([captured], markerHidden: true)
        XCTAssertEqual(resolved[0].items.filter { $0.bundle == own }.map(\.id), ["MenuBox.main"])
        captured.items.remove(at: 3)
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([captured], markerHidden: true))
    }

    func testHiddenReplicaResolvesBoxWithoutMatchingTrailingOffset() throws {
        var reference = hiddenBar(bar(-200)), replica = hiddenBar(bar(0))
        reference.items[0] = item("MenuBox.main", own, -100)
        replica.items[0] = .init(id: "own", bundle: own,
            frame: CGRect(x: 70, y: 0, width: 20, height: 24), identifier: "")
        XCTAssertEqual(try NativeMenuBarSnapshot.resolveControls([reference, replica], markerHidden: true)
            .flatMap(\.items).filter { $0.bundle == own }.map(\.id), ["MenuBox.main", "MenuBox.main"])
    }

    func testCollapsedMarkerRemainsRegisteredAcrossDisplayReplicas() throws {
        var reference = bar(0), replica = bar(-200)
        reference.items[2] = .init(id: "marker", bundle: own,
            frame: CGRect(x: 70, y: 0, width: 16, height: 24), identifier: "MenuBox.marker")
        replica.items[2] = .init(id: "replica-marker", bundle: own,
            frame: CGRect(x: -130, y: 0, width: 16, height: 24), identifier: "")
        replica.items[3] = .init(id: "replica-box", bundle: own,
            frame: replica.items[3].frame, identifier: "")
        let resolved = try NativeMenuBarSnapshot.resolveControls([reference, replica], markerHidden: true)
        for bar in resolved {
            XCTAssertEqual(bar.items.filter { $0.bundle == own }.map(\.id), ["MenuBox.main"])
            XCTAssertTrue(bar.items.contains { $0.id == "focus" })
        }
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([reference, replica], markerHidden: false),
            "Do not plan a new section before the marker has expanded")
    }

    func testCollapsedMarkerFilteringNeverDiscardsOtherIconsOrAVisibleMarker() throws {
        var captured = bar(0)
        captured.items[0] = .init(id: "narrow-app", bundle: "one",
            frame: CGRect(x: 10, y: 0, width: 8, height: 24), identifier: "")
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([captured], markerHidden: true))
        captured.items[2] = .init(id: "marker", bundle: own,
            frame: CGRect(x: 70, y: 0, width: 16, height: 24), identifier: "MenuBox.marker")
        let resolved = try NativeMenuBarSnapshot.resolveControls([captured], markerHidden: true)
        XCTAssertTrue(resolved[0].items.contains { $0.id == "narrow-app" })
        captured.items.removeAll { $0.id == "MenuBox.main" }
        XCTAssertThrowsError(try NativeMenuBarSnapshot.resolveControls([captured], markerHidden: true))
    }

    func testLaptopOnlyOverflowNeedsNoFullyExpandedReferenceDisplay() throws {
        let snapshot = NativeMenuBarSnapshot(bars: [bar(0, overflow: true)], executables: [:])
        XCTAssertEqual(try snapshot.plan().applicationKeys, ["one", "two"])
    }

    func testReferenceCannotOverrideDifferentSideOnAnotherDisplay() {
        var other = bar(0)
        other.items[0] = item("one", "one", 175)
        let snapshot = NativeMenuBarSnapshot(bars: [bar(-200), other], executables: [:])
        XCTAssertThrowsError(try snapshot.plan())
    }

    func testVerificationRejectsMissingBoxOrFocusAndReappearingHiddenApp() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var hidden = bar(0)
        hidden.items.removeAll { ["one", "two"].contains($0.bundle) }
        XCTAssertNoThrow(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one", "two"], comparedTo: before))
        for missing in ["MenuBox.main", "focus"] {
            var damaged = hidden
            damaged.items.removeAll { $0.id == missing }
            XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [damaged], executables: [:])
                .verifyHidden(["one", "two"], comparedTo: before))
        }
        XCTAssertThrowsError(try before.verifyHidden(["one", "two"], comparedTo: before))
    }

    func testHiddenMarkerIsRequiredToDisappearButBoxAndFocusMustRemain() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var hidden = bar(0)
        hidden.items.removeAll { ["one", "two"].contains($0.bundle) || $0.id == "MenuBox.marker" }
        XCTAssertNoThrow(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one", "two"], comparedTo: before, markerHidden: true))
        hidden.items.append(item("MenuBox.marker", own, 70))
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one", "two"], comparedTo: before, markerHidden: true))
    }

    func testSystemRelayoutDoesNotUndoSuccessfulHiding() throws {
        var original = bar(0)
        original.items.append(item("transient", "com.apple.MenuBarAgent", 170))
        original.items[5] = .init(id: "transient", bundle: "com.apple.MenuBarAgent",
            frame: original.items[5].frame, identifier: "plus")
        let before = NativeMenuBarSnapshot(bars: [original], executables: [:])
        let hidden = NativeMenuBarSnapshot.Bar(frame: original.frame, items: [
            item("MenuBox.main", own, 120), item("focus", "com.apple.MenuBarAgent", 160)
        ])
        XCTAssertNoThrow(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one", "two"], comparedTo: before, markerHidden: true))
    }

    func testIndividualSystemHidingStillRequiresUnselectedSystemControls() throws {
        var original = bar(0)
        original.items[1] = item("now-playing", "com.apple.MenuBarAgent", 35)
        let before = NativeMenuBarSnapshot(bars: [original], executables: [:])
        var hidden = original
        hidden.items.removeAll { ["one", "now-playing", "MenuBox.marker"].contains($0.id) }
        XCTAssertNoThrow(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one"], comparedTo: before, markerHidden: true, systemItems: ["now-playing"]))
        var reappeared = hidden
        reappeared.items.append(original.items[1])
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [reappeared], executables: [:])
            .verifyHidden(["one"], comparedTo: before, markerHidden: true, systemItems: ["now-playing"]))
        hidden.items.removeAll { $0.id == "focus" }
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .verifyHidden(["one"], comparedTo: before, markerHidden: true, systemItems: ["now-playing"]))
    }

    func testTemporaryActivityIndicatorCannotBlockOrUndoAppHiding() throws {
        var visible = bar(0)
        let indicator = item("com.apple.menuextra.audiovideo", "com.apple.MenuBarAgent", 58)
        visible.items.append(indicator)
        let before = NativeMenuBarSnapshot(bars: [visible], executables: [:])
        let plan = try before.plan()
        XCTAssertEqual(plan.applicationKeys, ["one", "two"])
        XCTAssertTrue(plan.systemItemIDs.isEmpty, "Activity indicators must never be written to visibility preferences")
        var hidden = visible
        hidden.items.removeAll { ["one", "two", "MenuBox.marker"].contains($0.id) }
        let withIndicator = NativeMenuBarSnapshot(bars: [hidden], executables: [:])
        XCTAssertEqual(try withIndicator.hiddenState(plan.applicationKeys, comparedTo: before, systemItems: []), .hidden)
        hidden.items.removeAll { $0.id == indicator.id }
        let withoutIndicator = NativeMenuBarSnapshot(bars: [hidden], executables: [:])
        XCTAssertEqual(withIndicator.membershipSignature, withoutIndicator.membershipSignature)
        XCTAssertEqual(try withoutIndicator.hiddenState(plan.applicationKeys, comparedTo: before, systemItems: []), .hidden)
    }
    func testHiddenStateSeparatesReappearingTargetsFromActualLayoutChanges() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var current = bar(0)
        current.items.removeAll { ["one", "two", "MenuBox.marker"].contains($0.id) }
        func state() throws -> NativeMenuBarSnapshot.HiddenState {
            try NativeMenuBarSnapshot(bars: [current], executables: [:])
                .hiddenState(["one", "two"], comparedTo: before, systemItems: [])
        }
        XCTAssertEqual(try state(), .hidden)
        current.items.insert(item("one", "one", 10), at: 0)
        XCTAssertEqual(try state(), .targetsVisible)
        current.items.append(item("new", "new", 170))
        XCTAssertEqual(try state(), .layoutChanged)
        current.items.removeLast()
        current.items.removeAll { $0.id == "focus" }
        XCTAssertEqual(try state(), .layoutChanged)
    }

    private func hiddenBar(_ source: NativeMenuBarSnapshot.Bar) -> NativeMenuBarSnapshot.Bar {
        .init(frame: source.frame, items: source.items.filter { !["one", "two", "MenuBox.marker"].contains($0.id) })
    }

    func testAddsCollapsedLeftItemsUsingLiveNeighborInsteadOfOldMarkerCoordinates() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var hidden = hiddenBar(bar(0))
        hidden.items[0] = item("MenuBox.main", own, 140)
        hidden.items[1] = item("focus", "com.apple.MenuBarAgent", 180)
        hidden.items += [item("new-one", "new-one", 110), item("new-two", "new-two", 110)]
        let actual = NativeMenuBarSnapshot(bars: [hidden], executables: [:])
        let update = try actual.addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        XCTAssertEqual(update.plan.applicationKeys, ["one", "two", "new-one", "new-two"])
        hidden.items.removeAll { $0.bundle.hasPrefix("new-") }
        XCTAssertEqual(try NativeMenuBarSnapshot(bars: [hidden], executables: [:]).hiddenState(
            update.plan.applicationKeys, comparedTo: update.baseline, systemItems: []), .hidden)
    }

    func testHiddenAdditionsAllowDifferentInventoriesOnEachDisplay() throws {
        var external = bar(-200)
        external.items.append(item("external-only", "external-only", -30))
        let before = NativeMenuBarSnapshot(bars: [external, bar(0)], executables: [:])
        var laptop = hiddenBar(bar(0))
        laptop.items.append(item("new-left", "new-left", 30))
        let update = try NativeMenuBarSnapshot(bars: [hiddenBar(external), laptop], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        XCTAssertEqual(update.plan.applicationKeys, ["one", "two", "new-left"])
        XCTAssertTrue(update.plan.protectedItemsByDisplay[external.id]!.contains("external-only"))
    }

    func testNewLeftSystemReplicaCannotHideExistingProtectedReplica() throws {
        let id = NativeSystemMenuBarPreferences.Setting.nowPlaying.itemID
        var external = bar(-200)
        external.items.append(item(id, "com.apple.MenuBarAgent", -30))
        let before = NativeMenuBarSnapshot(bars: [external, bar(0)], executables: [:])
        var laptop = hiddenBar(bar(0))
        laptop.items.append(item(id, "com.apple.MenuBarAgent", 30))
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [hiddenBar(external), laptop], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan()))
    }

    func testConsecutiveAdditionsUseOriginalBoundaryAndKeepAllOwnershipReferences() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var hidden = hiddenBar(bar(0))
        hidden.items.append(item("third", "third", 65))
        let first = try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        hidden.items.removeLast()
        hidden.items.append(item("fourth", "fourth", 65))
        let second = try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .addingItemsWhileHidden(comparedTo: first.baseline, boundaryReference: before, plan: first.plan)
        XCTAssertEqual(second.plan.applicationKeys, ["one", "two", "third", "fourth"])
        XCTAssertTrue(Set(second.baseline.bars[0].items.map(\.bundle)).isSuperset(of: second.plan.applicationKeys))
    }

    func testNewRightSideItemIsProtectedAndNeverSelected() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        var hidden = hiddenBar(bar(0))
        hidden.items.append(item("new-right", "new-right", 170))
        let update = try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        XCTAssertEqual(update.plan.applicationKeys, ["one", "two"])
        XCTAssertTrue(update.plan.protectedItemsByDisplay[hidden.id]!.contains("new-right"))
    }

    func testRejectsNewApplicationOnDifferentSidesAcrossDisplays() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(-200), bar(0)], executables: [:])
        var left = hiddenBar(bar(-200)), right = hiddenBar(bar(0))
        left.items.append(item("new", "new", -170))
        right.items.append(item("new", "new", 170))
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan()))
    }

    func testRejectsNewItemOverlappingAnchorAndMissingProtectedItems() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(0)], executables: [:])
        for x: CGFloat in [105, 30] {
            var hidden = hiddenBar(bar(0))
            hidden.items.append(item("new", "new", x))
            if x == 30 { hidden.items.removeAll { $0.id == "focus" } }
            XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [hidden], executables: [:])
                .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan()))
        }
    }

    func testNewSystemControlUsesIndividualIDAndMustAgreeAcrossDisplays() throws {
        let before = NativeMenuBarSnapshot(bars: [bar(-200), bar(0)], executables: [:])
        var left = hiddenBar(bar(-200)), right = hiddenBar(bar(0))
        let id = NativeSystemMenuBarPreferences.Setting.nowPlaying.itemID
        left.items.append(item(id, "com.apple.MenuBarAgent", -170))
        right.items.append(item(id, "com.apple.MenuBarAgent", 30))
        let update = try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan())
        XCTAssertEqual(update.plan.applicationKeys, ["one", "two"])
        XCTAssertEqual(update.plan.systemItemIDs, [id])
        right.items[right.items.count - 1] = item(id, "com.apple.MenuBarAgent", 170)
        XCTAssertThrowsError(try NativeMenuBarSnapshot(bars: [left, right], executables: [:])
            .addingItemsWhileHidden(comparedTo: before, boundaryReference: before, plan: before.plan()))
    }

}
