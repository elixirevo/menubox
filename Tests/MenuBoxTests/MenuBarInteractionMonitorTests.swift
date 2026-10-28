// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import XCTest
@testable import MenuBox

final class MenuBarInteractionMonitorTests: XCTestCase {
    private let anchor = CGPoint(x: 700, y: 12)
    private let frame = CGRect(x: 650, y: 25, width: 220, height: 300)
    private var menuLevel: Int { Int(CGWindowLevelForKey(.popUpMenuWindow)) }

    func testNativeMenuKeepsInteractionActiveWithoutPointerInsideIt() {
        let menu = StatusItemEventRouter.Window(id: 1, ownerPID: 42, frame: frame, layer: menuLevel)
        XCTAssertTrue(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [menu], visibleBefore: [1], accessibilityFrames: []))
        XCTAssertFalse(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [], visibleBefore: [1], accessibilityFrames: []))
    }

    func testForeignMenusAndOrdinaryAppWindowsDoNotBlockHiding() {
        let other = StatusItemEventRouter.Window(id: 1, ownerPID: 43, frame: frame, layer: menuLevel)
        let main = StatusItemEventRouter.Window(id: 2, ownerPID: 42, frame: frame, layer: 0)
        XCTAssertFalse(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [other, main], visibleBefore: [2], accessibilityFrames: []))
    }

    func testCustomPopoverNeedsAXMatchAndSurvivesLateMouseDelivery() {
        let popup = StatusItemEventRouter.Window(id: 1, ownerPID: 42, frame: frame, layer: 0)
        XCTAssertTrue(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [popup], visibleBefore: [], accessibilityFrames: [frame]))
        XCTAssertTrue(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [popup], visibleBefore: [1], accessibilityFrames: [frame]))
        XCTAssertFalse(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [popup], visibleBefore: [], accessibilityFrames: []))
    }

    func testSingleItemMenuIsNotMistakenForTheStatusIcon() {
        let tiny = StatusItemEventRouter.Window(id: 1, ownerPID: 42,
            frame: CGRect(x: 690, y: 25, width: 100, height: 24), layer: menuLevel)
        XCTAssertTrue(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [tiny], visibleBefore: [], accessibilityFrames: []))
        let icon = StatusItemEventRouter.Window(id: 2, ownerPID: 42,
            frame: CGRect(x: 690, y: 0, width: 20, height: 24), layer: Int(CGWindowLevelForKey(.statusWindow)))
        XCTAssertFalse(MenuBarInteractionMonitor.hasPopup(ownerPID: 42, anchor: anchor,
            windows: [icon], visibleBefore: [], accessibilityFrames: []))
    }

    @MainActor
    func testLivePopupKeepsMonitorActiveUntilItsWindowCloses() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Needs a display") }
        let popup = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
            width: 220, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.level = NSWindow.Level(rawValue: menuLevel)
        popup.isReleasedWhenClosed = false
        popup.orderFrontRegardless()
        defer { popup.close() }
        let point = NSPoint(x: popup.frame.midX, y: popup.frame.maxY + 12)
        let target = MenuBarProxyTarget(appKitFrame: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
            appKitClickPoint: point, accessibilityElement: AXUIElementCreateApplication(getpid()),
            role: "AXMenuBarItem", title: "Test", description: "Test", actions: [],
            processIdentifier: getpid(), bundleIdentifier: "MenuBox.interaction-test", appName: "Test", icon: nil)
        let monitor = MenuBarInteractionMonitor()
        defer { monitor.stop() }
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        monitor.setEnabled(true)
        monitor.observe(target)
        try await Task.sleep(nanoseconds: 650_000_000)
        monitor.refresh()
        XCTAssertTrue(monitor.isActive, "A visible popup must outlive the mouse-release grace period")
        popup.orderOut(nil)
        // WindowServer can publish the disappearance after orderOut returns.
        for _ in 0..<20 where monitor.isActive {
            try await Task.sleep(nanoseconds: 50_000_000)
            monitor.refresh()
        }
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(changes, [true, false], "Polling must emit only the actual start/end transitions")
    }
}
