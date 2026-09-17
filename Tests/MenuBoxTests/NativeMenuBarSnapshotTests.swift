import CoreGraphics
import XCTest
@testable import MenuBox

final class NativeMenuBarSnapshotTests: XCTestCase {
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
