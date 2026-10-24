// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import XCTest
@testable import MenuBox

@MainActor
final class HidingNoticeSuppressionTests: XCTestCase {
    private func plan(_ names: [String], reason: String = "unsupported", hasHiddenIcons: Bool = true) -> MenuBarSectionPlanner.Plan {
        .init(applicationKeys: hasHiddenIcons ? ["good"] : [], protectedItemsByDisplay: [:], systemItemIDs: [],
              exclusions: names.map { .init(owner: .system($0), reason: reason) })
    }

    func testSuppressionSurvivesRestartAndIgnoresItemOrder() throws {
        let suite = "MenuBox.suppression.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HidingNoticeIdentity.partial(plan(["AirDrop", "Bluetooth"]))
        let reordered = HidingNoticeIdentity.partial(plan(["Bluetooth", "AirDrop"]))
        XCTAssertEqual(first, reordered)
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.shouldShowHidingNotice(first))
        store.suppressHidingNotice(first)
        let restarted = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(restarted.shouldShowHidingNotice(reordered))
        restarted.resetToDefaults()
        XCTAssertTrue(restarted.shouldShowHidingNotice(first))
    }

    func testAddedRemovedOrChangedCauseAndOutcomeShowAgain() throws {
        let suite = "MenuBox.suppression.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let original = HidingNoticeIdentity.partial(plan(["AirDrop", "Bluetooth"]))
        for changed in [plan(["AirDrop", "Bluetooth", "Other"]), plan(["AirDrop"]),
                        plan(["AirDrop", "Bluetooth"], reason: "invalid geometry"),
                        plan(["AirDrop", "Bluetooth"], hasHiddenIcons: false)] {
            store.suppressHidingNotice(original)
            XCTAssertTrue(store.shouldShowHidingNotice(HidingNoticeIdentity.partial(changed)))
            XCTAssertTrue(store.shouldShowHidingNotice(original), "A changed notice resets the old suppression")
        }
    }

    func testButtonSuppressesOnlyCurrentNoticeWhileOKOnlyClosesIt() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Needs a display") }
        let suite = "MenuBox.suppression-ui.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let box = BoxWindowController(settingsStore: store)
        defer { box.close() }
        let identity = HidingNoticeIdentity.partial(plan(["AirDrop", "Bluetooth"]))
        let anchor = MenuBarGeometry.menuBarRect(for: screen)
        box.showHidingError("AirDrop, Bluetooth", noticeIdentifier: identity, anchorFrame: anchor, screen: screen)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "MenuBox.hidingError" && $0.isVisible })
        let suppress = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "MenuBox.suppressHidingNotice" })
        XCTAssertEqual(suppress.title, menuBoxLocalized("Don’t show again"))
        suppress.performClick(nil)
        XCTAssertFalse(box.isShowing)
        // A language/name change alone does not override a semantic identity.
        box.showHidingError("Translated notice", noticeIdentifier: identity, anchorFrame: anchor, screen: screen)
        XCTAssertFalse(box.isShowing)
        let changed = HidingNoticeIdentity.partial(plan(["AirDrop"]))
        box.showHidingError("AirDrop", noticeIdentifier: changed, anchorFrame: anchor, screen: screen)
        XCTAssertTrue(box.isShowing)
        let nextPanel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "MenuBox.hidingError" && $0.isVisible })
        let ok = try XCTUnwrap(nextPanel.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == menuBoxLocalized("OK") })
        ok.performClick(nil)
        XCTAssertFalse(box.isShowing)
        box.showHidingError("AirDrop", noticeIdentifier: changed, anchorFrame: anchor, screen: screen)
        XCTAssertTrue(box.isShowing, "OK must not persist a suppression choice")
    }
}
