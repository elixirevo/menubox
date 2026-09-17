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

    func testSystemOnlyJournalPreservesApplicationPreferences() throws {
        let original = try document([("right", true, ["right"])])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: original.data,
            previousAllowed: [:], systemChanges: [.init(setting: .nowPlaying, original: nil)])
        XCTAssertEqual(try NativeMenuBarRecovery.restorationData(journal, current: original), original.data)
    }
    func testReapplyRetainsOriginalRecoveryValuesAndUnrelatedChanges() throws {
        let original = try document([("left", true, ["left"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        let reset = try document([("left", true, ["left"]), ("right", false, ["right"])])
        let reapplied = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.reapplicationData(journal, current: reset))
        XCTAssertEqual(reapplied.records["left"]?.allowed, false)
        XCTAssertEqual(reapplied.records["right"]?.allowed, false)
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: reapplied))
        XCTAssertEqual(restored.records["left"]?.allowed, true)
        XCTAssertEqual(restored.records["right"]?.allowed, false)
    }

    func testReapplyRejectsNewUnrelatedOwnerLocation() throws {
        let original = try document([("left", true, ["left"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        let reassigned = try document([("left", true, ["left", "right"]), ("right", true, ["right"])])
        XCTAssertThrowsError(try NativeMenuBarRecovery.reapplicationData(journal, current: reassigned))
    }

    func testTemporaryRevealChangesOnlySelectedAppAndKeepsRecoveryBaseline() throws {
        let original = try document([("left", true, ["left"]), ("second", true, ["second"]),
                                     ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false, "second": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
                                                    previousAllowed: ["left": true, "second": true])
        let current = try NativeMenuBarPreferences.decode(written)
        let shown = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.temporaryRevealData(journal,
            current: current, bundle: "left", visible: ["left", "second", "right"], executables: [:]))
        XCTAssertEqual(shown.records["left"]?.allowed, true)
        XCTAssertEqual(shown.records["second"]?.allowed, false)
        XCTAssertEqual(shown.records["right"]?.allowed, true)
        XCTAssertEqual(NSArray(array: Array(shown.entries.dropFirst(2))),
                       NSArray(array: Array(current.entries.dropFirst(2))))
        let rehidden = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.reapplicationData(journal, current: shown))
        XCTAssertEqual(rehidden.records["left"]?.allowed, false)
        XCTAssertEqual(rehidden.records["second"]?.allowed, false)
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: rehidden))
        XCTAssertEqual(NSArray(array: restored.entries), NSArray(array: original.entries))
    }

    func testTemporaryRevealRejectsSharedOwnerAndUnselectedApp() throws {
        let original = try document([("owner", true, ["one", "two"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["owner": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
                                                    previousAllowed: ["owner": true])
        for bundle in ["one", "right", NativeMenuBarPreferences.ownBundle] {
            XCTAssertThrowsError(try NativeMenuBarRecovery.temporaryRevealData(journal,
                current: NativeMenuBarPreferences.decode(written), bundle: bundle,
                visible: ["one", "two", "right"], executables: [:]))
        }
    }

    func testTemporaryRevealSupportsUniquelyAttributedHelper() throws {
        let original = try document([("owner", true, ["helper"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["owner": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
                                                    previousAllowed: ["owner": true])
        let shown = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.temporaryRevealData(journal,
            current: NativeMenuBarPreferences.decode(written), bundle: "helper", visible: ["helper"], executables: [:]))
        XCTAssertEqual(shown.records["owner"]?.allowed, true)
    }

    func testExtendedJournalKeepsExistingIconsHiddenAndRestoresBothOriginalFlags() throws {
        let original = try document([("left", true, ["left"]), ("right", true, ["right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        // The app creates its record later; an unrelated app was disabled meanwhile.
        let current = try document([("left", false, ["left"]), ("right", false, ["right"]), ("new", true, ["new"])])
        let extended = try NativeMenuBarRecovery.extending(journal, current: current,
            applications: ["new"], visible: ["left", "right", "new"], executables: [:])
        XCTAssertEqual(extended.previousAllowed, ["left": true, "new": true])
        let applied = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.reapplicationData(extended, current: current))
        XCTAssertEqual(applied.records["left"]?.allowed, false)
        XCTAssertEqual(applied.records["new"]?.allowed, false)
        XCTAssertEqual(applied.records["right"]?.allowed, false)
        for interrupted in [current, applied] {
            let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(extended, current: interrupted))
            XCTAssertEqual(restored.records["left"]?.allowed, true)
            XCTAssertEqual(restored.records["new"]?.allowed, true)
            XCTAssertEqual(restored.records["right"]?.allowed, false)
        }
    }

    func testSuccessiveExtensionsRetainSelfLocationRepairsAndMenuLeaseSupport() throws {
        let original = try document([("launcher", true, ["old-child"]), ("second", true, []), ("third", true, ["third"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["launcher": false], includingSelfLocations: ["launcher"])
        let initial = NativeMenuBarRecovery.Journal(original: original.data, written: written,
            previousAllowed: ["launcher": true], addedSelfLocations: ["launcher"])
        let first = try NativeMenuBarRecovery.extending(initial, current: NativeMenuBarPreferences.decode(written),
            applications: ["second"], visible: ["launcher", "second", "third"], executables: [:])
        let second = try NativeMenuBarRecovery.extending(first, current: NativeMenuBarPreferences.decode(first.written),
            applications: ["third"], visible: ["launcher", "second", "third"], executables: [:])
        XCTAssertEqual(second.previousAllowed, ["launcher": true, "second": true, "third": true])
        XCTAssertEqual(second.addedSelfLocations, ["launcher", "second"])
        let current = try NativeMenuBarPreferences.decode(second.written)
        let menuShown = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.temporaryRevealData(second,
            current: current, bundle: "third", visible: ["launcher", "second", "third"], executables: [:]))
        XCTAssertEqual(menuShown.records["launcher"]?.allowed, false)
        XCTAssertEqual(menuShown.records["second"]?.allowed, false)
        XCTAssertEqual(menuShown.records["third"]?.allowed, true)
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(second, current: current))
        XCTAssertTrue(restored.records.values.allSatisfy(\.allowed))
        XCTAssertEqual(restored.records["launcher"]?.locations.compactMap(NativeMenuBarPreferences.bundle), ["old-child", "launcher"])
    }

    func testExtensionRejectsSharedRightSideOwnerBeforeChangingJournal() throws {
        let original = try document([("left", true, ["left"]), ("owner", true, ["new", "right"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written, previousAllowed: ["left": true])
        XCTAssertThrowsError(try NativeMenuBarRecovery.extending(journal, current: NativeMenuBarPreferences.decode(written),
            applications: ["new"], visible: ["left", "new", "right"], executables: [:]))
    }

    func testSystemOnlyExtensionRetainsPreviousApplicationAndSystemRestoration() throws {
        let original = try document([("left", true, ["left"])])
        let written = try NativeMenuBarPreferences.changing(original, allowed: ["left": false])
        let journal = NativeMenuBarRecovery.Journal(original: original.data, written: written,
            previousAllowed: ["left": true], systemChanges: [.init(setting: .inputMenu, original: .boolean(true))])
        let extended = try NativeMenuBarRecovery.extending(journal, current: NativeMenuBarPreferences.decode(written),
            applications: [], visible: ["left"], executables: [:], systemChanges: [.init(setting: .nowPlaying, original: nil)])
        XCTAssertEqual(extended.previousAllowed, journal.previousAllowed)
        XCTAssertEqual(extended.systemChanges?.map(\.setting), [.inputMenu, .nowPlaying])
        let restored = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(
            extended, current: NativeMenuBarPreferences.decode(written)))
        // Re-encoding a binary plist can reorder its object table. Compare all
        // restored values, including unknown fields, rather than encoded bytes.
        XCTAssertEqual(NSArray(array: restored.entries), NSArray(array: original.entries))
    }

}
