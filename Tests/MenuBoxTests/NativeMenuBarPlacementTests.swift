import Foundation
import XCTest
@testable import MenuBox

final class NativeMenuBarPlacementTests: XCTestCase {
    private let app = "com.example.dynamic"
    private var key: String { "status:\(app)::Item-0" }
    private var positions: [String: Double] {
        [NativeMenuBarPlacement.boxKey: 400, "module:Clock": 0,
         "status:com.example.neighbor::Item-0": 353,
         "status:com.elixirevo.MenuBox::com.elixirevo.MenuBox.tape": 438, key: 800]
    }

    func testMovesOnlySelectedItemBesideBoxAndRestoresOriginalPosition() throws {
        let change = try NativeMenuBarPlacement.plan(bundle: app, identifier: "Item-0", positions: positions)
        let moved = try NativeMenuBarPlacement.applying(change, to: positions)
        XCTAssertEqual(change.temporary, 376.5)
        XCTAssertEqual(moved.filter { $0.key != key }, positions.filter { $0.key != key })
        XCTAssertEqual(moved[key], 376.5)
        XCTAssertEqual(NativeMenuBarPlacement.restoring(change, in: moved), positions)
    }

    func testRestorePreservesOtherAppsAndNewIcons() throws {
        let change = try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: positions)
        var current = try NativeMenuBarPlacement.applying(change, to: positions)
        current["module:Clock"] = 1
        current["status:com.example.new::Item-0"] = 777
        let restored = NativeMenuBarPlacement.restoring(change, in: current)
        XCTAssertEqual(restored[key], 800)
        XCTAssertEqual(restored["module:Clock"], 1)
        XCTAssertEqual(restored["status:com.example.new::Item-0"], 777)
    }

    func testRestoreRespectsManualTargetMoveOrRemoval() throws {
        let change = try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: positions)
        var current = try NativeMenuBarPlacement.applying(change, to: positions)
        current[key] = 555
        XCTAssertEqual(NativeMenuBarPlacement.restoring(change, in: current), current)
        current.removeValue(forKey: key)
        XCTAssertEqual(NativeMenuBarPlacement.restoring(change, in: current), current)
    }

    func testRejectsChangedTargetAndAmbiguousAppIdentity() throws {
        let change = try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: positions)
        var current = positions
        current[key] = 900
        XCTAssertThrowsError(try NativeMenuBarPlacement.applying(change, to: current))
        current["status:\(app)::Item-1"] = 840
        XCTAssertThrowsError(try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: current))
        XCTAssertThrowsError(try NativeMenuBarPlacement.plan(bundle: app, identifier: "Missing", positions: current))
        XCTAssertEqual(try NativeMenuBarPlacement.plan(bundle: app, identifier: "Item-1", positions: current).original, 840)
    }

    func testRefusesSystemOwnAndAlreadyRightOfBoxItems() throws {
        for bundle in ["", "com.apple.controlcenter", NativeMenuBarPreferences.ownBundle, "com.example.missing"] {
            XCTAssertThrowsError(try NativeMenuBarPlacement.plan(bundle: bundle, identifier: "", positions: positions))
        }
        var current = positions
        current[key] = 300
        XCTAssertThrowsError(try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: current))
        current.removeValue(forKey: NativeMenuBarPlacement.boxKey)
        XCTAssertThrowsError(try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: current))
    }

    func testPreferenceSchemaRejectsMalformedValues() throws {
        XCTAssertEqual(try NativeMenuBarPlacement.decode(["item": NSNumber(value: 927.5)]), ["item": 927.5])
        let invalid: [Any] = [[:], ["item": true], ["item": "400"], ["item": -1], ["item": Double.nan]]
        for value in invalid { XCTAssertThrowsError(try NativeMenuBarPlacement.decode(value)) }
        XCTAssertThrowsError(try NativeMenuBarPlacement.decode(nil))
    }

    func testJournalRoundTripAndRepeatedRestoration() throws {
        let change = try NativeMenuBarPlacement.plan(bundle: app, identifier: "", positions: positions)
        let recovered = try PropertyListDecoder().decode(NativeMenuBarPlacement.Change.self,
            from: PropertyListEncoder().encode(change))
        XCTAssertEqual(change, recovered)
        let current = try NativeMenuBarPlacement.applying(recovered, to: positions)
        let restored = NativeMenuBarPlacement.restoring(recovered, in: current)
        XCTAssertEqual(NativeMenuBarPlacement.restoring(recovered, in: restored), positions)
    }
}
