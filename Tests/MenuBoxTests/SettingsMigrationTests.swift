import XCTest
@testable import MenuBox

final class SettingsMigrationTests: XCTestCase {
    func testStatusBoxSettingsAndPositionsAreImportedWithoutDeletingLegacyData() throws {
        let name = "MenuBoxTests.Migration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = AppSettings.defaults
        legacy.boxMaxColumns = 7
        legacy.autoHideDelaySeconds = 12
        legacy.shortcutsEnabled = false
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "StatusBox.AppSettings.v3")
        defaults.set(412.0, forKey: "NSStatusItem Preferred Position com.elixirevo.StatusBox.main")
        defaults.set(false, forKey: "NSStatusItem Visible com.elixirevo.StatusBox.tape")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.boxMaxColumns, 7)
        XCTAssertEqual(store.settings.autoHideDelaySeconds, 12)
        XCTAssertFalse(store.settings.shortcutsEnabled)
        XCTAssertEqual(defaults.double(forKey: "NSStatusItem Preferred Position com.elixirevo.MenuBox.main"), 412)
        XCTAssertEqual(defaults.object(forKey: "NSStatusItem Visible com.elixirevo.MenuBox.tape") as? Bool, false)
        XCTAssertEqual(defaults.data(forKey: "StatusBox.AppSettings.v3"), data)

        store.update { $0.boxMaxColumns = 9 }
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.boxMaxColumns, 9)
    }

    func testMigrationDoesNotOverwriteExistingMenuBoxSettingsOrPositions() throws {
        let name = "MenuBoxTests.Migration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var existing = AppSettings.defaults
        existing.boxMaxColumns = 4
        defaults.set(try JSONEncoder().encode(existing), forKey: "MenuBox.AppSettings.v3")
        defaults.set(try JSONEncoder().encode(AppSettings.defaults), forKey: "StatusBox.AppSettings.v3")
        defaults.set(100.0, forKey: "NSStatusItem Preferred Position com.elixirevo.StatusBox.main")
        defaults.set(200.0, forKey: "NSStatusItem Preferred Position com.elixirevo.MenuBox.main")

        XCTAssertEqual(SettingsStore(defaults: defaults).settings.boxMaxColumns, 4)
        XCTAssertEqual(defaults.double(forKey: "NSStatusItem Preferred Position com.elixirevo.MenuBox.main"), 200)
    }
}
