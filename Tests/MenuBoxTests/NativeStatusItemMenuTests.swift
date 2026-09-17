import XCTest
import CoreGraphics
@testable import MenuBox

@MainActor
final class NativeStatusItemMenuTests: XCTestCase {
    private func item(_ title: String) -> MenuBarProxyMenuItem {
        .init(title: title, identity: title, role: "AXMenuItem", actions: [], accessibilityElement: nil,
              appKitFrame: nil, isSeparator: false, isEnabled: true, isChecked: false, children: [])
    }

    func testAttachedMenuCanBeReadWhenNoClickRouteExists() async {
        let menu = await NativeStatusItemMenu.read(attached: { [self.item("Settings")] },
            request: { XCTFail("Attached menu must not be opened through a click"); return false },
            opened: { XCTFail("No popup was requested"); return nil })
        XCTAssertEqual(menu?.items.map(\.title), ["Settings"])
        XCTAssertTrue(menu?.roots.isEmpty == true)
    }

    func testAttachedMenuDoesNotTouchVisibleStatusIconEvenWithClickRoute() async {
        let menu = await NativeStatusItemMenu.read(
            rightClick: { XCTFail("A readable menu must not trigger a menu-bar popup"); return true },
            attached: { [self.item("Settings")] },
            request: { XCTFail("Do not request AXShowMenu"); return true },
            opened: { XCTFail("No native popup should be opened or observed"); return nil })
        XCTAssertEqual(menu?.items.map(\.title), ["Settings"])
        XCTAssertTrue(menu?.roots.isEmpty == true)
        XCTAssertNil(menu?.presentation)
    }

    func testRightClickBuildsMenuWithoutAXShowMenuSupport() async {
        var clicked = false, waits = 0
        let menu = await NativeStatusItemMenu.read(
            rightClick: { clicked = true; return true },
            attached: { [] },
            request: { XCTFail("A dispatched right click must not be duplicated by AXShowMenu"); return false },
            opened: {
                clicked && waits >= 2 ? .init(items: [self.item("Generated on right click")], roots: []) : nil
            }, wait: { waits += 1 })
        XCTAssertEqual(menu?.items.map(\.title), ["Generated on right click"])
        XCTAssertEqual(waits, 2)
    }

    func testClickWaitsForRebuiltMenuInsteadOfReturningStaleAttachedMenu() async {
        var waits = 0, clicked = false
        let menu = await NativeStatusItemMenu.read(
            rightClick: { clicked = true; return true },
            attached: { clicked ? [self.item("Old command")] : [] },
            request: { false },
            opened: { waits >= 20 ? .init(items: [self.item("Current command")], roots: []) : nil },
            wait: { waits += 1 })
        XCTAssertEqual(menu?.items.map(\.title), ["Current command"])
        XCTAssertEqual(waits, 20, "Allow a dynamic menu more than the old 800 ms timeout")
    }

    func testSuccessfulEventPostingAloneDoesNotCountAsAMenu() async {
        var waits = 0
        let menu = await NativeStatusItemMenu.read(rightClick: { true }, attached: { [] },
            request: { XCTFail("Do not send a second request after the click"); return true },
            opened: { nil }, wait: { waits += 1 })
        XCTAssertNil(menu)
        XCTAssertEqual(waits, 30)
    }

    func testCustomPanelWithoutMenuItemsIsACompletedOpenRequest() async {
        var waits = 0, cleanups = 0
        let presentation = StatusItemMenuPresentation(windowID: 42, ownerPID: 7,
            frame: CGRect(x: 100, y: 34, width: 402, height: 91))
        let panel = OpenedStatusItemMenu(items: [], roots: [], presentation: presentation,
            kind: .customPopup, onCancel: { cleanups += 1 })
        let result = await NativeStatusItemMenu.read(rightClick: { true }, attached: { [] },
            request: { XCTFail("Do not reopen a successful custom panel"); return false },
            opened: { waits == 1 ? panel : nil }, wait: { waits += 1 })
        XCTAssertTrue(result === panel, "A custom UI is success even with no AXMenuItem")
        XCTAssertEqual(waits, 1, "Do not continue polling toward an erroneous timeout")
        XCTAssertTrue(panel.keepsNativePresentation(usesNativeHiding: true, isBesideBox: false),
            "A panel anchored to its own icon cannot be replaced with an empty proxy")
        XCTAssertTrue(panel.keepsNativePresentation(usesNativeHiding: false, isBesideBox: false))
        XCTAssertEqual(cleanups, 0)
        // The user can close the panel before the caller starts watching it.
        await NativeStatusItemMenu.keepVisibleUntilClosed(panel, isVisible: { false }, wait: {
            XCTFail("An already dismissed panel has completed normally")
        })
        XCTAssertEqual(cleanups, 1)
        panel.cancel()
        XCTAssertEqual(cleanups, 1)
    }

    func testCustomPanelRemainsInteractiveUntilItActuallyCloses() async {
        var waits = 0, cleanups = 0
        let panel = OpenedStatusItemMenu(items: [], roots: [],
            presentation: .init(windowID: 42, ownerPID: 7, frame: .zero),
            kind: .customPopup, onCancel: { cleanups += 1 })
        await NativeStatusItemMenu.keepVisibleUntilClosed(panel, isVisible: { waits < 60 }, wait: {
            XCTAssertEqual(cleanups, 0)
            waits += 1
        })
        XCTAssertEqual(waits, 60, "The request timeout must not end a successfully opened custom UI")
        XCTAssertEqual(cleanups, 1)
    }

    func testOrdinaryMenusKeepTheirExistingPresentationRules() {
        let menu = OpenedStatusItemMenu(items: [item("Settings")], roots: [],
            presentation: .init(windowID: 42, ownerPID: 7, frame: .zero))
        XCTAssertTrue(menu.keepsNativePresentation(usesNativeHiding: true, isBesideBox: true))
        XCTAssertFalse(menu.keepsNativePresentation(usesNativeHiding: true, isBesideBox: false))
        XCTAssertFalse(menu.keepsNativePresentation(usesNativeHiding: false, isBesideBox: true))
    }

    func testCancellationDuringRoutingDoesNotSendAFallbackAction() async {
        var reads = 0
        let task = Task { @MainActor in
            await NativeStatusItemMenu.read(rightClick: {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }, attached: { reads += 1; XCTAssertEqual(reads, 1, "Do not read again after cancellation"); return [] },
            request: { XCTFail("Cancelled request must not request a popup"); return true }, opened: { nil })
        }
        let menu = await task.value
        XCTAssertNil(menu)
    }

    func testCancellationStillObservesAndRejectsALatePopup() async {
        var waits = 0, cleanups = 0, reads = 0
        let task = Task { @MainActor in
            await NativeStatusItemMenu.read(rightClick: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }, attached: { reads += 1; XCTAssertEqual(reads, 1, "Do not return attached contents after cancellation"); return [] },
            request: { false },
            opened: { waits == 2 ? .init(items: [self.item("Late menu")], roots: [], onCancel: { cleanups += 1 }) : nil },
            wait: { waits += 1 })
        }
        let menu = await task.value
        XCTAssertNil(menu)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(cleanups, 1)
    }

    func testMenuRetainsTemporaryVisibilityUntilCommandOrPresentationFinishes() async {
        var visible = true, cleanups = 0
        let menu = await NativeStatusItemMenu.read(rightClick: { true }, attached: { [] },
            request: { false }, opened: {
                .init(items: [self.item("Settings")], roots: [], onCancel: {
                    visible = false
                    cleanups += 1
                })
            })
        XCTAssertTrue(visible, "The native command must remain alive until the caller executes it")
        menu?.cancel()
        XCTAssertFalse(visible)
        menu?.cancel()
        XCTAssertEqual(cleanups, 1, "Repeated dismissal must not repeat visibility changes")
    }

    func testExplicitMenuRequestCanPopulateDynamicMenu() async {
        var requests = 0, waits = 0
        let menu = await NativeStatusItemMenu.read(attached: { waits > 1 ? [self.item("New item")] : [] },
            request: { requests += 1; return true }, opened: { nil }, wait: { waits += 1 })
        XCTAssertEqual(menu?.items.map(\.title), ["New item"])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(waits, 2)
    }

    func testNativePresentationKeepsLeaseUntilOriginalMenuCloses() async {
        var waits = 0, cleanups = 0
        let menu = OpenedStatusItemMenu(items: [item("Settings")], roots: [], onCancel: { cleanups += 1 })
        await NativeStatusItemMenu.keepVisibleUntilClosed(menu, isVisible: { waits < 3 }, wait: {
            XCTAssertEqual(cleanups, 0, "The native menu must remain usable without being dismissed or rehidden")
            waits += 1
        })
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(cleanups, 1)
        menu.cancel()
        menu.finish()
        XCTAssertEqual(cleanups, 1)
    }

    func testReplacingNativePresentationCancelsAndReleasesLease() async {
        var cleanups = 0
        let menu = OpenedStatusItemMenu(items: [item("Settings")], roots: [], onCancel: { cleanups += 1 })
        let task = Task { @MainActor in
            await NativeStatusItemMenu.keepVisibleUntilClosed(menu, isVisible: { true }, wait: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await task.value
        XCTAssertEqual(cleanups, 1)
    }

    func testUnavailableMenuStopsWithoutRetryingAnUnsupportedAction() async {
        var requests = 0
        let menu = await NativeStatusItemMenu.read(attached: { [] }, request: { requests += 1; return false },
            opened: { XCTFail("Unsupported menu must not be polled"); return nil })
        XCTAssertNil(menu)
        XCTAssertEqual(requests, 1)
    }

    func testSelectionUsesFreshContentsAndRejectsChangedPath() async {
        let original = item("Settings")
        let selection = MenuBarProxyMenuSelection(item: original, path: ["Settings"], identityPath: ["Settings"])
        let current = item("Settings")
        let menu = await NativeStatusItemMenu.read(attached: { [current] }, request: { false }, opened: { nil })
        XCTAssertTrue(MenuBarProxyScanner.currentMenuItem(matching: selection, in: menu!.items) === current)
        let changed = await NativeStatusItemMenu.read(attached: { [self.item("Quit")] }, request: { false }, opened: { nil })
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection, in: changed!.items))
    }

    func testRepeatedReadUsesCurrentAttachedContentsWithoutOpeningNativeMenu() async {
        var current = [item("Enable")]
        func read() async -> OpenedStatusItemMenu? {
            await NativeStatusItemMenu.read(
                rightClick: { XCTFail("Do not click while rereading an attached menu"); return true },
                attached: { current }, request: { false }, opened: { nil })
        }
        let shown = await read()
        current = [item("Disable")]
        let selected = await read()
        XCTAssertEqual(shown?.items.map(\.title), ["Enable"])
        XCTAssertEqual(selected?.items.map(\.title), ["Disable"])
        let selection = MenuBarProxyMenuSelection(item: shown!.items[0], path: ["Enable"], identityPath: ["Enable"])
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection, in: selected!.items))
    }
}
