import XCTest
import CoreGraphics
@testable import MenuBox

final class StatusItemMenuPresentationTests: XCTestCase {
    private func window(_ id: CGWindowID, pid: pid_t = 7, layer: Int = 101,
                        frame: CGRect = CGRect(x: -739, y: -286, width: 402, height: 91)) -> StatusItemEventRouter.Window {
        .init(id: id, ownerPID: pid, frame: frame, layer: layer)
    }

    func testCustomPopupRequiresNewAppOwnedPopupWindow() {
        let candidates = StatusItemMenuPresentation.customPopupCandidates(ownerPID: 7,
            visibleBeforeRequest: [1], windows: [
                window(1), window(2), window(3, pid: 8), window(4, layer: 0),
                window(5, frame: CGRect(x: 100, y: 0, width: 30, height: 24)),
                window(6, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
            ])
        XCTAssertEqual(candidates.map(\.id), [2])
    }

    func testCustomPopupMatchesAXDialogIncludingReusedPreviouslyOffscreenWindow() {
        // AlDente reuses a window ID. Only visibility before dispatch matters,
        // not whether the window was already allocated while offscreen.
        let candidate = window(78)
        let candidates = StatusItemMenuPresentation.customPopupCandidates(ownerPID: 7,
            visibleBeforeRequest: [], windows: [candidate])
        let popup = StatusItemMenuPresentation.matchingCustomPopup(windows: candidates,
            dialogFrames: [candidate.frame])
        XCTAssertEqual(popup?.windowID, 78)
        XCTAssertEqual(popup?.ownerPID, 7)
    }

    func testUnmatchedAndAmbiguousCustomWindowsAreNotAdopted() {
        XCTAssertNil(StatusItemMenuPresentation.matchingCustomPopup(windows: [window(1)], dialogFrames: []))
        XCTAssertNil(StatusItemMenuPresentation.matchingCustomPopup(windows: [window(1)],
            dialogFrames: [CGRect(x: 500, y: 500, width: 402, height: 91)]))
        XCTAssertNil(StatusItemMenuPresentation.matchingCustomPopup(windows: [window(1), window(2)],
            dialogFrames: [window(1).frame]))
    }

    func testUsesMenuAtClickedBoxRowWithoutAdoptingMenuBarPopup() {
        let box = CGRect(x: 1000, y: 41, width: 312, height: 100)
        let anchor = CGPoint(x: 1020, y: 76)
        XCTAssertTrue(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 1018, y: 61, width: 260, height: 162), box: box, anchor: anchor))
        XCTAssertTrue(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 1149, y: 97, width: 260, height: 162), box: box, anchor: anchor),
            "Keep the native menu if the pointer moved within Box before delivery")
        XCTAssertFalse(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 1018, y: 34, width: 260, height: 162), box: box, anchor: anchor))
        XCTAssertFalse(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 300, y: 61, width: 260, height: 162), box: box, anchor: anchor))
        XCTAssertFalse(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 1500, y: 61, width: 260, height: 162), box: box,
            anchor: CGPoint(x: 1500, y: 76)))
    }

    func testSupportsPopupFlippedLeftAtDisplayEdgeAndOtherBoxRows() {
        let box = CGRect(x: 1400, y: 41, width: 312, height: 100)
        XCTAssertTrue(StatusItemMenuPresentation.isBesideBox(
            menu: CGRect(x: 1440, y: 94, width: 260, height: 162), box: box,
            anchor: CGPoint(x: 1680, y: 112)))
    }
}
