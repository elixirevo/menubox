import Foundation
import XCTest
@testable import MenuBox

final class NativeMenuBarPreferencesTests: XCTestCase {
    private func location(_ bundle: String) -> [String: Any] { ["bundle": ["_0": bundle]] }
    private func document(_ records: [(String, Bool, [String])]) throws -> NativeMenuBarPreferences.Document {
        let entries: [Any] = records.flatMap { bundle, allowed, items -> [Any] in
            [location(bundle), ["location": location(bundle), "isAllowed": allowed,
                               "menuItemLocations": items.map(location), "futureField": "preserve"]]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        return try NativeMenuBarPreferences.decode(data)
    }

    func testChangesOnlySelectedAllowedFlagPreservingUnknownFieldsAndDisabledApps() throws {
        let original = try document([("left", true, ["left"]), ("disabled", false, ["disabled"]),
                                     ("right", true, ["right"])])
        let data = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let changed = try NativeMenuBarPreferences.decode(data)
        XCTAssertEqual(changed.records["left"]?.allowed, false)
        XCTAssertEqual(changed.records["disabled"]?.allowed, false)
        XCTAssertEqual(changed.records["right"]?.allowed, true)
        XCTAssertEqual((changed.entries[1] as? [String: Any])?["futureField"] as? String, "preserve")
        XCTAssertEqual(NSArray(array: Array(changed.entries.dropFirst(2))), NSArray(array: Array(original.entries.dropFirst(2))))
    }

    func testRefusesRecordWhoseHelperBelongsToRightSide() throws {
        let doc = try document([("left", true, ["left", "right"])])
        XCTAssertThrowsError(try NativeMenuBarPreferences.controlKeys(for: ["left"], visible: ["left", "right"],
                                                                     executables: [:], in: doc))
    }

    func testOwnControlsCannotBeHiddenThroughForeignAttribution() throws {
        let doc = try document([("left", true, ["left", NativeMenuBarPreferences.ownBundle])])
        XCTAssertThrowsError(try NativeMenuBarPreferences.controlKeys(for: ["left"], visible: ["left"],
                                                                     executables: [:], in: doc))
    }

    func testResolvesHelperToItsUniqueControllingRecord() throws {
        let doc = try document([("owner", true, ["helper"])])
        XCTAssertEqual(try NativeMenuBarPreferences.controlKeys(for: ["helper"], visible: ["helper"],
                                                               executables: [:], in: doc), ["owner"])
    }

    func testRejectsAmbiguousHelperAttribution() throws {
        let doc = try document([("one", true, ["helper"]), ("two", true, ["helper"])])
        XCTAssertThrowsError(try NativeMenuBarPreferences.controlKeys(for: ["helper"], visible: ["helper"],
                                                                     executables: [:], in: doc))
    }

    func testNeverWritesMenuBoxOwnRecord() throws {
        let doc = try document([(NativeMenuBarPreferences.ownBundle, true, [])])
        XCTAssertThrowsError(try NativeMenuBarPreferences.changing(doc, allowed: [NativeMenuBarPreferences.ownBundle: false]))
    }

    func testRecoveryRestoresOriginalBytesWhenThereAreNoConcurrentEdits() throws {
        let original = try document([("left", true, ["left"]), ("disabled", false, [])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        XCTAssertEqual(try NativeMenuBarRecovery.restorationData(journal, current: NativeMenuBarPreferences.decode(written)), original.data)
    }

    func testRecoveryPreservesUnrelatedPreferenceEdit() throws {
        let original = try document([("left", true, ["left"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        let concurrent = try NativeMenuBarPreferences.decode(NativeMenuBarPreferences.changing(original,
            allowed: ["left": false, "right": false]))
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: concurrent))
        XCTAssertEqual(restored.records["left"]?.allowed, true)
        XCTAssertEqual(restored.records["right"]?.allowed, false)
    }

    func testRecoveryRejectsJournalThatChangesUnrecordedApplication() throws {
        let original = try document([("left", true, []), ("right", true, [])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false, "right": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        XCTAssertThrowsError(try NativeMenuBarRecovery.restorationData(journal, current: NativeMenuBarPreferences.decode(written)))
    }

    func testLauncherVisibilityRestoresWithCorrectedLiveIdentity() throws {
        let original = try document([("launcher", true, ["old-child"]), ("right", true, ["right"])])
        let additions = NativeMenuBarPreferences.missingSelfLocations(for: ["launcher"], keys: ["launcher"],
                                                                      executables: [:], in: original)
        XCTAssertEqual(additions, ["launcher"])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["launcher": false],
                                                            includingSelfLocations: additions)
        let changed = try NativeMenuBarPreferences.decode(written)
        XCTAssertEqual(changed.records["launcher"]?.locations.compactMap(NativeMenuBarPreferences.bundle),
                       ["old-child", "launcher"])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
            previousAllowed: ["launcher": true], addedSelfLocations: additions)
        let shown = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: changed))
        XCTAssertEqual(shown.records["launcher"]?.allowed, true)
        XCTAssertEqual(shown.records["launcher"]?.locations.compactMap(NativeMenuBarPreferences.bundle), ["old-child", "launcher"])
        let concurrent = try NativeMenuBarPreferences.decode(NativeMenuBarPreferences.changing(changed, allowed: ["right": false]))
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: concurrent))
        XCTAssertEqual(restored.records["launcher"]?.locations.compactMap(NativeMenuBarPreferences.bundle), ["old-child", "launcher"])
        XCTAssertEqual(restored.records["launcher"]?.allowed, true)
        XCTAssertEqual(restored.records["right"]?.allowed, false)
    }

    func testResolvedHelperDoesNotGainUnrelatedOwnerLocation() throws {
        let doc = try document([("owner", true, ["helper"])])
        XCTAssertTrue(NativeMenuBarPreferences.missingSelfLocations(for: ["helper"], keys: ["owner"],
                                                                   executables: [:], in: doc).isEmpty)
    }
}
