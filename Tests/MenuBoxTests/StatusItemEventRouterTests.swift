import AppKit
import ApplicationServices
import XCTest
@testable import MenuBox

final class StatusItemEventRouterTests: XCTestCase {
    private let itemFrame = CGRect(x: -6017, y: -320, width: 24, height: 24)

    private func window(_ id: CGWindowID, pid: pid_t = 20, x: CGFloat = -6024,
                        width: CGFloat = 38, layer: Int = 25) -> StatusItemEventRouter.Window {
        .init(id: id, ownerPID: pid, frame: CGRect(x: x, y: -323, width: width, height: 30), layer: layer)
    }

    func testResolvesOffscreenHostedItemInsteadOfDisplayReplica() {
        let result = StatusItemEventRouter.matchingWindow(
            itemFrame: itemFrame, targetPID: 10, hostPID: 20,
            windows: [window(1, x: -8584), window(2), window(3, x: -5986)]
        )
        XCTAssertEqual(result?.id, 2)
        XCTAssertEqual(result?.ownerPID, 20)
    }

    func testResolvesAppOwnedStatusWindow() {
        XCTAssertEqual(StatusItemEventRouter.matchingWindow(
            itemFrame: itemFrame, targetPID: 10, hostPID: nil, windows: [window(1, pid: 10)]
        )?.id, 1)
    }

    func testRejectsAmbiguousOrUnrelatedWindows() {
        for windows in [[window(1), window(2)], [window(1, pid: 30)],
                        [window(1, width: 5016)], [window(1, layer: 101)]] {
            XCTAssertNil(StatusItemEventRouter.matchingWindow(
                itemFrame: itemFrame, targetPID: 10, hostPID: 20, windows: windows
            ))
        }
    }

    func testVisibleHostAllowsButtonHitAreaBeyondSceneBounds() {
        let host = CGRect(x: 1141.5, y: 0, width: 40, height: 33)
        let button = CGRect(x: 1140, y: 3.5, width: 42, height: 26)
        XCTAssertTrue(StatusItemEventRouter.hostFrameMatchesItem(host, item: button))
        XCTAssertFalse(StatusItemEventRouter.hostFrameMatchesItem(host.offsetBy(dx: 40, dy: 0), item: button))
        XCTAssertFalse(StatusItemEventRouter.hostFrameMatchesItem(
            CGRect(x: 0, y: 0, width: 1728, height: 33), item: button))
        XCTAssertFalse(StatusItemEventRouter.hostFrameMatchesItem(host, item: .zero))
    }

    func testDetachedMenuProbeRejectsForeignAndUnrelatedWindows() {
        let popup = CGRect(x: 1208, y: 34, width: 260, height: 162)
        let icon = CGPoint(x: 1208, y: 16.5)
        XCTAssertTrue(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup, targetPoint: icon))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: false, layer: 101, bounds: popup, targetPoint: icon))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 0, bounds: popup, targetPoint: icon))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup.offsetBy(dx: -1100, dy: 0), targetPoint: icon))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup.offsetBy(dx: 0, dy: 600), targetPoint: icon))
    }

    func testDetachedPopupAtBoxClickPointAwayFromStatusIcon() {
        let icon = CGPoint(x: 1208, y: 16.5)
        let pointer = CGPoint(x: 400, y: 600)
        let popup = CGRect(x: 400, y: 596, width: 260, height: 162)
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup, targetPoint: icon))
        XCTAssertTrue(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup, targetPoint: icon, popupPoint: pointer))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: false, layer: 101, bounds: popup, targetPoint: icon, popupPoint: pointer))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 0, bounds: popup, targetPoint: icon, popupPoint: pointer))
        XCTAssertFalse(MenuBarProxyScanner.isOwnedStatusMenuPopup(
            ownerMatchesTarget: true, layer: 101, bounds: popup.offsetBy(dx: 300, dy: 0),
            targetPoint: icon, popupPoint: pointer))
    }

    private func menuItem(_ title: String, enabled: Bool = true,
                          children: [MenuBarProxyMenuItem] = []) -> MenuBarProxyMenuItem {
        .init(title: title, identity: title, role: "AXMenuItem", actions: [],
              accessibilityElement: nil, appKitFrame: nil, isSeparator: false,
              isEnabled: enabled, isChecked: false, children: children)
    }

    func testSelectionRequiresUniqueEnabledItemAtOriginalPath() {
        let item = menuItem("Open")
        let selection = MenuBarProxyMenuSelection(item: item, path: ["Tools", "Open"],
                                                  identityPath: ["Tools", "Open"])
        XCTAssertTrue(MenuBarProxyScanner.currentMenuItem(matching: selection,
            in: [menuItem("Tools", children: [item])]) === item)
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection, in: [item]))
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection,
            in: [menuItem("Tools", children: [item, menuItem("Open")])]))
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection,
            in: [menuItem("Tools", children: [menuItem("Open", enabled: false)])]))
        XCTAssertNil(MenuBarProxyScanner.currentMenuItem(matching: selection,
            in: [menuItem("Tools", enabled: false, children: [item])]))
    }

    /// Opt in on a developer Mac with an already-running menu bar app.
    /// No commands are selected; the app's generated menu is dismissed via AXCancel.
    @MainActor
    func testLiveNativeMenuWithoutMovingCursor() async throws {
        guard let bundleID = ProcessInfo.processInfo.environment["MENUBOX_MENU_TEST_BUNDLE_ID"] else {
            throw XCTSkip("Set MENUBOX_MENU_TEST_BUNDLE_ID to run the native menu integration check")
        }
        XCTAssertTrue(AXIsProcessTrusted())
        let apps = MenuBarProxyScanner.runningApplicationInfo(excludingProcessIdentifier: getpid())
            .filter { $0.bundleIdentifier == bundleID }
        let target = try XCTUnwrap(MenuBarProxyScanner.statusItemTargets(runningApplications: apps).first)
        let originalFrame = target.appKitFrame
        let pointer = try XCTUnwrap(CGEvent(source: nil)?.location)
        let sent = await StatusItemEventRouter.postRightClick(to: target)
        XCTAssertTrue(sent)
        var opened: OpenedStatusItemMenu?
        for _ in 0..<20 {
            opened = MenuBarProxyScanner.openedStatusItemMenu(for: target)
            if opened != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { opened?.cancel() }
        XCTAssertEqual(CGEvent(source: nil)?.location, pointer, "The router must not move the real pointer")
        XCTAssertEqual(MenuBarProxyScanner.refreshedTarget(from: target)?.appKitFrame, originalFrame,
                       "The hidden status item must stay in place")
        let menu = try XCTUnwrap(opened, "The app must actually generate its native menu")
        XCTAssertTrue(menu.items.contains { !$0.isSeparator })
        print("Native menu from \(bundleID): \(menu.items.map(\.title))")
    }
}
