import AppKit
import ApplicationServices
import XCTest
@testable import MenuBox

final class MenuBarTargetInventoryTests: XCTestCase {
    func testSingleExtrasMenuBarElementIsNotDiscardedAsAnIncompleteArray() {
        let element = AXUIElementCreateApplication(123)
        let bars = MenuBarProxyScanner.statusItemElements(from: element)
        XCTAssertEqual(bars?.count, 1)
        XCTAssertTrue(bars.map { CFEqual($0[0], element) } ?? false)
    }

    func testChildrenArrayAndEmptyArrayRemainCompleteObservations() {
        let element = AXUIElementCreateApplication(123)
        XCTAssertEqual(MenuBarProxyScanner.statusItemElements(from: [element] as CFArray)?.count, 1)
        XCTAssertEqual(MenuBarProxyScanner.statusItemElements(from: [] as CFArray)?.count, 0)
    }

    func testMissingOrInvalidAXValueIsNotReportedAsAnEmptyList() {
        XCTAssertNil(MenuBarProxyScanner.statusItemElements(from: nil))
        XCTAssertNil(MenuBarProxyScanner.statusItemElements(from: "invalid" as CFString))
    }

    func testLiveInventoryFindsRequestedOwnersWithoutRevealingIcons() throws {
        guard let bundles = ProcessInfo.processInfo.environment["MENUBOX_INVENTORY_TEST_BUNDLES"] else {
            throw XCTSkip("Opt-in read-only scan of running status-item owners")
        }
        let expected = Set(bundles.split(separator: ",").map(String.init))
        XCTAssertTrue(AXIsProcessTrusted())
        let apps = MenuBarProxyScanner.runningApplicationInfo(excludingProcessIdentifier: getpid())
        let report = MenuBarProxyScanner.scanStatusItems(runningApplications: apps)
        let found = Set(report.targets.map(\.bundleIdentifier))
        XCTAssertTrue(expected.isSubset(of: found), "Missing owners: \(expected.subtracting(found))")
        print("LIVE_INVENTORY", report.targets.map { "\($0.bundleIdentifier):\($0.displayName)" }.sorted())
    }

    private func target(_ pid: pid_t, bundle: String? = nil, id: String = "", x: CGFloat = 983) -> MenuBarProxyTarget {
        let frame = CGRect(x: x, y: 4.5, width: 24, height: 24)
        return MenuBarProxyTarget(appKitFrame: frame, appKitClickPoint: .init(x: frame.midX, y: frame.midY),
            accessibilityElement: AXUIElementCreateApplication(pid), role: "AXMenuBarItem", title: "",
            description: "", actions: [], processIdentifier: pid, bundleIdentifier: bundle ?? "app.\(pid)",
            appName: "App \(pid)", icon: nil, identifier: id)
    }

    private func owners(_ targets: [MenuBarProxyTarget]) -> [pid_t: String] {
        Dictionary(targets.map { ($0.processIdentifier, $0.bundleIdentifier) }, uniquingKeysWith: { a, _ in a })
    }

    func testFourteenCollapsedIconsWithIdenticalFramesAndLabelsRemainDistinct() {
        let items = (1...14).map { target(pid_t($0)) }
        XCTAssertEqual(Set(items.map(\.identity)).count, 14)
        var inventory = MenuBarTargetInventory()
        inventory.merge(items, runningOwners: owners(items), completeOwners: [], preservingApplications: [])
        XCTAssertEqual(inventory.targets.count, 14)
    }

    func testIdentifiersAreScopedToOwnerAndRetainMultipleItemsOfOneApp() {
        let items = [target(1, id: "status"), target(2, id: "status"), target(1, id: "second")]
        XCTAssertEqual(Set(items.map(\.identity)).count, 3)
        var inventory = MenuBarTargetInventory()
        inventory.merge(items + [target(1, id: "status", x: 1500)], runningOwners: owners(items),
                        completeOwners: [], preservingApplications: [])
        XCTAssertEqual(inventory.targets.count, 3)
        XCTAssertEqual(inventory.targets.first?.appKitFrame.minX, 1500)
    }

    func testMovingAnAXElementUpdatesRoutingWithoutDuplicatingOrReorderingIt() {
        let first = target(1), second = target(2)
        var inventory = MenuBarTargetInventory()
        inventory.merge([first, second], runningOwners: owners([first, second]),
                        completeOwners: [], preservingApplications: [])
        let moved = target(1, x: 2000)
        XCTAssertEqual(first.identity, moved.identity)
        inventory.merge([second, moved], runningOwners: owners([first, second]),
                        completeOwners: [], preservingApplications: [])
        XCTAssertEqual(inventory.targets.map(\.processIdentifier), [1, 2])
        XCTAssertTrue(inventory.targets[0] === moved)
    }

    func testPartialNonemptyScanDoesNotReplacePreviouslyDiscoveredIcons() {
        let items = (1...14).map { target(pid_t($0)) }
        var inventory = MenuBarTargetInventory()
        inventory.merge(items, runningOwners: owners(items), completeOwners: [], preservingApplications: [])
        for _ in 0..<3 {
            inventory.merge(Array(items.prefix(12)), runningOwners: owners(items),
                            completeOwners: Set(1...12), preservingApplications: [])
        }
        XCTAssertEqual(inventory.targets.count, 14)
    }

    func testRemovingAStatusItemRequiresTwoConsecutiveCompleteObservations() {
        let item = target(1)
        var inventory = MenuBarTargetInventory()
        inventory.merge([item], runningOwners: owners([item]), completeOwners: [1], preservingApplications: [])
        inventory.merge([], runningOwners: owners([item]), completeOwners: [1], preservingApplications: [])
        XCTAssertEqual(inventory.targets.count, 1)
        // An unavailable AX tree breaks the sequence; it is not proof of removal.
        inventory.merge([], runningOwners: owners([item]), completeOwners: [], preservingApplications: [])
        inventory.merge([], runningOwners: owners([item]), completeOwners: [1], preservingApplications: [])
        XCTAssertEqual(inventory.targets.count, 1)
        inventory.merge([], runningOwners: owners([item]), completeOwners: [1], preservingApplications: [])
        XCTAssertTrue(inventory.targets.isEmpty)
    }

    func testHiddenItemsSurviveEmptyAXListsAndNewAppsAreMergedWhileHidden() {
        let old = target(1), new = target(2)
        var inventory = MenuBarTargetInventory()
        inventory.merge([old], runningOwners: owners([old]), completeOwners: [1], preservingApplications: [])
        for _ in 0..<3 {
            inventory.merge([new], runningOwners: owners([old, new]), completeOwners: [1, 2],
                            preservingApplications: [old.bundleIdentifier, new.bundleIdentifier])
        }
        XCTAssertEqual(inventory.targets.map(\.processIdentifier), [1, 2])
    }

    func testTerminatedOwnersArePrunedEvenWhenTheirBundleWasHidden() {
        let old = target(1), relaunched = target(2, bundle: old.bundleIdentifier)
        var inventory = MenuBarTargetInventory()
        inventory.merge([old], runningOwners: owners([old]), completeOwners: [], preservingApplications: [])
        inventory.merge([old, relaunched], runningOwners: owners([relaunched]), completeOwners: [],
                        preservingApplications: [old.bundleIdentifier])
        XCTAssertEqual(inventory.targets.map(\.processIdentifier), [2])
    }

    func testReusedPIDDoesNotKeepThePreviousApplicationsElement() {
        let old = target(1), replacement = target(1, bundle: "different.app")
        var inventory = MenuBarTargetInventory()
        inventory.merge([old], runningOwners: owners([old]), completeOwners: [], preservingApplications: [])
        inventory.merge([old, replacement], runningOwners: owners([replacement]), completeOwners: [],
                        preservingApplications: [old.bundleIdentifier])
        XCTAssertEqual(inventory.targets.map(\.bundleIdentifier), [replacement.bundleIdentifier])
    }

    func testActualSectionPlanExcludesRightSideItemsDespiteStaleLeftCoordinates() throws {
        let left = target(1, x: 3000), right = target(2, x: -1500)
        var inventory = MenuBarTargetInventory()
        inventory.merge([right, left], runningOwners: owners([left, right]), completeOwners: [], preservingApplications: [])
        let plan = try MenuBarSectionPlanner.plan(displays: [
            .init(id: "display", frame: .init(x: 0, y: 0, width: 250, height: 24), items: [
                .init(id: "left", owner: .application(left.bundleIdentifier), frame: .init(x: 10, y: 0, width: 20, height: 24)),
                .init(id: "marker", owner: .marker, frame: .init(x: 60, y: 0, width: 20, height: 24)),
                .init(id: "box", owner: .box, frame: .init(x: 100, y: 0, width: 20, height: 24)),
                .init(id: "right", owner: .application(right.bundleIdentifier), frame: .init(x: 140, y: 0, width: 20, height: 24))
            ], isResolved: true)
        ])
        XCTAssertEqual(inventory.selected(applications: plan.applicationKeys).map(\.bundleIdentifier), [left.bundleIdentifier])
        // Reclassifying the section must not need a new per-app AX frame.
        XCTAssertEqual(inventory.selected(applications: [right.bundleIdentifier]).map(\.bundleIdentifier), [right.bundleIdentifier])
        XCTAssertTrue(inventory.selected(applications: []).isEmpty)
    }
}
