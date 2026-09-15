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
}
