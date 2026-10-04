// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import XCTest
@testable import MenuBox

@MainActor
final class StatusItemMarkerPresentationTests: XCTestCase {
    func testRepeatedCollapseRetainsStatusItemAndRestoresAppearance() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let icon = StatusIconFactory.tapeIcon()
        item.button?.image = icon
        let presentation = StatusItemMarkerPresentation(item: item)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        for _ in 0..<5 {
            presentation.setHidden(true)
            let expandedFrame = presentation.expandedFrame
            presentation.setHidden(true)
            XCTAssertEqual(presentation.expandedFrame, expandedFrame)
            XCTAssertTrue(item.isVisible, "Hiding must not unregister the marker")
            XCTAssertTrue(item.button === button)
            XCTAssertTrue(button.window === window)
            XCTAssertTrue(button.image === icon, "Do not erase the client image ahead of the host layout")
            XCTAssertTrue(button.isEnabled, "Do not trigger a separate disabled-state redraw")
            XCTAssertEqual(item.length, 0)
            try await Task.sleep(nanoseconds: 10_000_000)
            presentation.setHidden(false)
            XCTAssertTrue(item.isVisible)
            XCTAssertTrue(button.window === window)
            XCTAssertTrue(button.image === icon)
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(item.length, NSStatusItem.squareLength)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCollapsedHostClipsIntactImageAndRestoresItsButtonGeometry() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            throw XCTSkip("Hosted menu bar geometry applies to macOS 27")
        }
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let icon = StatusIconFactory.tapeIcon()
        let button = try XCTUnwrap(item.button)
        button.image = icon
        let presentation = StatusItemMarkerPresentation(item: item)
        func waitForWidth(_ matches: (CGFloat) -> Bool) async throws {
            for _ in 0..<100 {
                if matches(button.frame.width) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Status button did not settle to the requested width")
        }
        try await waitForWidth { $0 > 0 }
        let width = button.frame.width
        presentation.setHidden(true)
        try await waitForWidth { $0 == 0 }
        XCTAssertTrue(button.image === icon)
        XCTAssertTrue(item.isVisible)
        presentation.setHidden(false)
        try await waitForWidth { $0 == width }
        XCTAssertTrue(button.image === icon)
    }
}
