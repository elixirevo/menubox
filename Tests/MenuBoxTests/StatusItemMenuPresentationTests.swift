import XCTest
@testable import MenuBox

final class StatusItemMenuPresentationTests: XCTestCase {
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
