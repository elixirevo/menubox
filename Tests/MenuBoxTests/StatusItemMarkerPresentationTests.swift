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
            XCTAssertNil(button.image)
            XCTAssertFalse(button.isEnabled)
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
}
