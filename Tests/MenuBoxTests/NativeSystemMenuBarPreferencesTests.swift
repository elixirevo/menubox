import XCTest
@testable import MenuBox

final class NativeSystemMenuBarPreferencesTests: XCTestCase {
    private typealias System = NativeSystemMenuBarPreferences

    func testSelectedControlsDoNotChangeRightFocusOrOtherSettings() throws {
        var values: [System.Setting: System.Value] = [.nowPlaying: .integer(2), .inputMenu: .boolean(true), .focus: .integer(18)]
        let changes: [System.Change] = [.init(setting: .nowPlaying, original: .integer(2)),
                                         .init(setting: .inputMenu, original: .boolean(true))]
        try System.apply(changes, read: { values[$0] }, write: { values[$1] = $0 })
        XCTAssertEqual(values[.nowPlaying], .integer(8))
        XCTAssertEqual(values[.inputMenu], .boolean(false))
        XCTAssertEqual(values[.focus], .integer(18))
        try System.restore(changes, read: { values[$0] }, write: { values[$1] = $0 })
        XCTAssertEqual(values[.nowPlaying], .integer(2))
        XCTAssertEqual(values[.inputMenu], .boolean(true))
        XCTAssertEqual(values[.focus], .integer(18))
    }

    func testRecoveryRestoresAbsentDefaultAndKeepsConcurrentUserChanges() throws {
        var values: [System.Setting: System.Value] = [.nowPlaying: .integer(8), .inputMenu: .boolean(true)]
        let changes: [System.Change] = [.init(setting: .nowPlaying, original: nil),
                                         .init(setting: .inputMenu, original: nil)]
        try System.restore(changes, read: { values[$0] }, write: { values[$1] = $0 })
        XCTAssertNil(values[.nowPlaying])
        XCTAssertEqual(values[.inputMenu], .boolean(true))
    }

    func testPartialFailureCanRestoreAlreadyAppliedControl() throws {
        var values: [System.Setting: System.Value] = [.nowPlaying: .integer(2), .inputMenu: .boolean(true)]
        let changes: [System.Change] = [.init(setting: .nowPlaying, original: .integer(2)),
                                         .init(setting: .inputMenu, original: .boolean(true))]
        XCTAssertThrowsError(try System.apply(changes, read: { values[$0] }, write: { value, setting in
            if setting == .inputMenu { throw System.Failure.write }
            values[setting] = value
        }))
        try System.restore(changes, read: { values[$0] }, write: { values[$1] = $0 })
        XCTAssertEqual(values[.nowPlaying], .integer(2))
        XCTAssertEqual(values[.inputMenu], .boolean(true))
    }

    func testMalformedOrDuplicateRecoveryEntryNeverWrites() {
        for changes: [System.Change] in [
            [.init(setting: .inputMenu, original: .integer(2))],
            [.init(setting: .nowPlaying, original: .boolean(true))],
            [.init(setting: .sound, original: .integer(-1))],
            [.init(setting: .nowPlaying, original: nil), .init(setting: .nowPlaying, original: nil)]
        ] {
            XCTAssertThrowsError(try System.restore(changes, read: { $0.hiddenValue }, write: { _, _ in XCTFail("Unexpected write") }))
        }
    }

    func testUnsupportedSystemIdentityDoesNotBecomeAnAppWideRestriction() {
        for id in ["com.apple.MenuBarAgent", "com.apple.MenuBarAgent:com.apple.menuextra.controlcenter", "com.elixirevo.MenuBox:0"] {
            XCTAssertThrowsError(try System.setting(for: id))
        }
    }
    func testReapplySkipsHiddenValuesRestoresResetControlsAndKeepsOriginals() throws {
        var values: [System.Setting: System.Value] = [.nowPlaying: .integer(8), .inputMenu: .boolean(true)]
        let changes: [System.Change] = [.init(setting: .nowPlaying, original: nil),
                                       .init(setting: .inputMenu, original: .boolean(true))]
        var writes = 0
        try System.reapply(changes, read: { values[$0] }, write: { values[$1] = $0; writes += 1 })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(values[.inputMenu], .boolean(false))
        try System.restore(changes, read: { values[$0] }, write: { values[$1] = $0 })
        XCTAssertNil(values[.nowPlaying])
        XCTAssertEqual(values[.inputMenu], .boolean(true))
        values[.nowPlaying] = .integer(18)
        XCTAssertThrowsError(try System.reapply(changes, read: { values[$0] }, write: { _, _ in XCTFail("Unexpected write") }))
    }

}
