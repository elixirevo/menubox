// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import XCTest
@testable import MenuBox

@MainActor
final class BoxHidingErrorTests: XCTestCase {
    func testErrorRemainsReadableWithAlertsDisabledAndDuringInventoryRefresh() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Needs a display") }
        let suite = "MenuBox.error-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update { $0.boxStatusMessagesEnabled = false }
        let controller = BoxWindowController(settingsStore: store)
        defer { controller.close() }
        let message = MenuBarSectionPlanner.Failure.applicationSpansBoundary("com.example.app").localizedDescription
        let anchor = MenuBarGeometry.menuBarRect(for: screen)
        controller.showHidingError(message, anchorFrame: anchor, screen: screen)
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "MenuBox.hidingError" && $0.isVisible })
        let content = try XCTUnwrap(window.contentView)
        let label = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == message })
        XCTAssertGreaterThan(label.frame.height, 20, "Long errors must wrap instead of being clipped to one icon's width")
        XCTAssertTrue(content.bounds.contains(label.frame))
        controller.refreshProxyTargets(anchorFrame: anchor, screen: screen, proxyTargets: [])
        XCTAssertTrue(window.contentView === content, "A periodic scan must not replace the error with an empty grid")
        let dismiss = try XCTUnwrap(content.subviews.compactMap { $0 as? NSButton }.first)
        dismiss.performClick(nil)
        XCTAssertFalse(controller.isShowing)
    }
}
