import CoreGraphics
import XCTest
@testable import MenuBox

final class MenuBarSectionPlannerTests: XCTestCase {
    private typealias Planner = MenuBarSectionPlanner

    private func item(_ id: String, _ owner: Planner.Owner, _ x: CGFloat) -> Planner.Item {
        .init(id: id, owner: owner, frame: CGRect(x: x, y: -323, width: 30, height: 30))
    }

    private func display(_ extras: [Planner.Item], id: String = "external",
                         resolved: Bool = true) -> Planner.Display {
        .init(id: id, frame: CGRect(x: -2560, y: -323, width: 2560, height: 30),
              items: extras + [item("marker", .marker, -630), item("box", .box, -590)],
              isResolved: resolved)
    }

    func testHidesLeftApplicationAndProtectsBothControlsAndRightFocus() throws {
        let result = try Planner.plan(displays: [display([
            item("ollama", .application("ollama"), -850),
            item("focus", .system("focus"), -390)
        ])])
        XCTAssertEqual(result.applicationKeys, ["ollama"])
        XCTAssertEqual(result.protectedItemsByDisplay["external"], ["box", "marker", "focus"])
    }

    func testWholeAppCannotBeHiddenWhenItsOtherIconIsOnRight() {
        XCTAssertThrowsError(try Planner.plan(displays: [display([
            item("first", .application("shared-app"), -850),
            item("second", .application("shared-app"), -500)
        ])])) { XCTAssertEqual($0 as? Planner.Failure, .applicationSpansBoundary("shared-app")) }
    }

    func testDisagreementBetweenDisplaysAlsoPreventsGlobalAppHiding() {
        XCTAssertThrowsError(try Planner.plan(displays: [
            display([item("app", .application("shared-app"), -850)], id: "one"),
            display([item("app", .application("shared-app"), -500)], id: "two")
        ])) { XCTAssertEqual($0 as? Planner.Failure, .applicationSpansBoundary("shared-app")) }
    }

    func testOverflowPlaceholdersWhollyLeftOfMarkerRemainEligible() throws {
        let plan = try Planner.plan(displays: [display([
            item("one", .application("one"), -850),
            item("two", .application("two"), -850)
        ])])
        XCTAssertEqual(plan.applicationKeys, ["one", "two"])
    }

    func testOverlappingMarkerOrProtectedItemsStillRejectsAmbiguousGeometry() {
        for extras in [
            [item("crossing", .application("app"), -645)],
            [item("right-one", .application("one"), -500), item("right-two", .application("two"), -500)],
            [item("box-overlap", .application("app"), -580)]
        ] {
            XCTAssertThrowsError(try Planner.plan(displays: [display(extras)])) {
                XCTAssertEqual($0 as? Planner.Failure, .ambiguousGeometry("external"))
            }
        }
    }

    func testSelectsIndividualSystemItemsOnLeftAndPreservesRightFocus() throws {
        let plan = try Planner.plan(displays: [display([
            item("now-playing", .system("now-playing"), -950),
            item("input-menu", .system("input-menu"), -900),
            item("app", .application("app"), -850),
            item("focus", .system("focus"), -400)
        ])])
        XCTAssertEqual(plan.applicationKeys, ["app"])
        XCTAssertEqual(plan.systemItemIDs, ["now-playing", "input-menu"])
        XCTAssertEqual(plan.protectedItemsByDisplay["external"],
                       ["box", "marker", "focus"])
    }

    func testMissingBoxCannotPassUsingMarkerFromSameProcess() {
        let incomplete = Planner.Display(id: "external", frame: display([]).frame,
                                         items: [item("marker", .marker, -630)], isResolved: true)
        XCTAssertThrowsError(try Planner.plan(displays: [incomplete])) {
            XCTAssertEqual($0 as? Planner.Failure, .missingOrAmbiguousControls("external"))
        }
    }

    func testUnresolvedSnapshotNeverProducesAPlan() {
        XCTAssertThrowsError(try Planner.plan(displays: [display([], resolved: false)])) {
            XCTAssertEqual($0 as? Planner.Failure, .incompleteSnapshot)
        }
    }

    func testBoxIsProtectedEvenWhenUserPlacesItLeftOfMarker() throws {
        let leftBox = Planner.Display(id: "external", frame: display([]).frame,
                                     items: [item("box", .box, -900),
                                             item("app", .application("app"), -800),
                                             item("marker", .marker, -630)], isResolved: true)
        let result = try Planner.plan(displays: [leftBox])
        XCTAssertEqual(result.applicationKeys, ["app"])
        XCTAssertEqual(result.protectedItemsByDisplay["external"], ["box", "marker"])
    }
}
