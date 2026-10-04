// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation
import MacAppCore
import MacAppDiagnosticsSentry
import XCTest
@testable import MenuBox

@MainActor
final class MenuBoxDiagnosticsTests: XCTestCase {
    private func configuration() throws -> SentryDiagnosticsConfiguration {
        try .init(dsn: "https://public@example.invalid/123", appIdentifier: "com.elixirevo.MenuBox",
                  version: "1.4.3", build: "146", environment: "test")
    }

    func testMissingConfigurationOmitsSettingsAndNeverStartsSDK() throws {
        var starts = 0
        let diagnostics = MenuBoxDiagnostics(preference: .init(activeEnabled: true, save: { _ in }),
            loadConfiguration: { nil }, startService: { configuration, _ in
                starts += 1
                return SentryDiagnostics(configuration: configuration)
            })
        try diagnostics.start()
        XCTAssertNil(diagnostics.settingsPreference)
        XCTAssertEqual(starts, 0)
    }

    func testDefaultOptOutAndChangingConsentWaitForNextLaunch() throws {
        let name = "MenuBoxTests.Diagnostics." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = CrashReportingPreference(defaults: defaults)
        var starts = 0
        let diagnostics = MenuBoxDiagnostics(preference: preference,
            loadConfiguration: { try self.configuration() }, startService: { configuration, _ in
                starts += 1
                return SentryDiagnostics(configuration: configuration)
            })
        try diagnostics.start()
        XCTAssertTrue(diagnostics.settingsPreference === preference)
        XCTAssertFalse(preference.activeEnabled)
        preference.select(true)
        try diagnostics.start()
        XCTAssertTrue(preference.requiresRestart)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(CrashReportingPreference(defaults: defaults).activeEnabled)
        SettingsStore(defaults: defaults).resetToDefaults(preservingLoginItem: true)
        XCTAssertTrue(defaults.bool(forKey: CrashReportingPreference.defaultKey))
    }

    func testOptInStartsOnlyOnceAndPreservesLaunchConsentWhenDisabled() throws {
        let preference = CrashReportingPreference(activeEnabled: true, save: { _ in })
        var starts = 0
        let diagnostics = MenuBoxDiagnostics(preference: preference,
            loadConfiguration: { try self.configuration() }, startService: { configuration, preference in
                XCTAssertTrue(preference.activeEnabled)
                starts += 1
                // A no-op test factory; never starts the actual Sentry SDK.
                return SentryDiagnostics(configuration: configuration)
            })
        try diagnostics.start()
        preference.select(false)
        try diagnostics.start()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(preference.requiresRestart)
        XCTAssertNotNil(diagnostics.service)
    }

    func testInvalidConfigurationDoesNotStartSDK() {
        let diagnostics = MenuBoxDiagnostics(loadConfiguration: { throw SentryConfigurationResourceError.invalidResource },
            startService: { _, _ in XCTFail("Must not start SDK"); throw SentryDiagnosticsError.startupFailed })
        XCTAssertThrowsError(try diagnostics.start())
        XCTAssertNil(diagnostics.settingsPreference)
    }

    func testBundledResourceMatchesMenuBoxAndUsesRunningReleaseMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.elixirevo.MenuBox", "CFBundleVersion": "999",
            "CFBundleShortVersionString": "2.0.0", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let config = try XCTUnwrap(MenuBoxDiagnostics.bundledConfiguration(appBundle: bundle))
        XCTAssertEqual(config.release, "com.elixirevo.MenuBox@2.0.0+999")
        XCTAssertEqual(config.environment, "production")
    }
}
