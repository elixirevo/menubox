// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppSettings
import XCTest
@testable import MenuBox

final class SettingsIntegrationTests: XCTestCase {
    func testShortcutRoundTripPreservesPhysicalKeyAndModifiers() {
        let value = KeyboardShortcutSetting(key: "F5", keyCode: 96, modifiers: [.command, .option, .shift])
        XCTAssertEqual(KeyboardShortcutSetting(value.settingsShortcut), value)
        XCTAssertEqual(KeyboardShortcutSetting.defaultBoxUI.settingsShortcut.keyCode, 11)
    }

    @MainActor
    func testRecorderRejectsDuplicateAndFailedWritesWithoutChangingSavedValues() throws {
        let name = "MenuBoxTests.Settings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        var writes = 0
        var recording = false
        let model = SettingsWindowController.makeShortcuts(store: store, actions: .init(
            showHiddenIcons: {}, hideHiddenIcons: {}, setShortcutRecordingActive: { recording = $0 },
            writeShortcut: { _, _ in writes += 1; throw MenuBoxSettingsError.shortcutUnavailable }
        ))
        model.beginRecording(id: "menuBarIcon")
        XCTAssertTrue(recording)
        model.setShortcut(store.settings.boxUIShortcut.settingsShortcut, for: "menuBarIcon")
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(model.errors["menuBarIcon"])
        model.setShortcut(.init(keyCode: 0, modifiers: [.command, .shift], keyLabel: "A"), for: "menuBarIcon")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(store.settings.menuBarIconShortcut, .defaultMenuBarIcon)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.menuBarIconShortcut, .defaultMenuBarIcon)
        XCTAssertNotNil(model.errors["menuBarIcon"])
        model.setShortcut(nil, for: "menuBarIcon")
        XCTAssertEqual(writes, 1)
        model.stopRecording()
        XCTAssertFalse(recording)
    }

    @MainActor
    func testSuccessfulShortcutWritePersistsAndEndsRecording() throws {
        let name = "MenuBoxTests.Settings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        var recording = false
        let model = SettingsWindowController.makeShortcuts(store: store, actions: .init(
            showHiddenIcons: {}, hideHiddenIcons: {}, setShortcutRecordingActive: { recording = $0 },
            writeShortcut: { _, shortcut in store.update { $0.menuBarIconShortcut = shortcut } }
        ))
        let shortcut = SettingsShortcut(keyCode: 0, modifiers: [.control, .option], keyLabel: "A")
        model.beginRecording(id: "menuBarIcon")
        model.setShortcut(shortcut, for: "menuBarIcon")
        XCTAssertFalse(recording)
        XCTAssertEqual(model.values["menuBarIcon"], shortcut)
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.menuBarIconShortcut, KeyboardShortcutSetting(shortcut))
    }

    @MainActor
    func testDiskAccessIsOSScopedAndUnknownDoesNotBecomeDeniedOrRequestAccess() async {
        var reads = 0
        var requests = 0
        let oldOS = SettingsWindowController.makePermissions(snapshot: .init(accessibility: false, fullDiskAccess: nil),
            readDiskAccess: { reads += 1; return .unavailable }, openDiskSettings: { requests += 1 })
        XCTAssertEqual(oldOS.permissions.map(\.id), ["accessibility"])
        let modernOS = SettingsWindowController.makePermissions(snapshot: .init(accessibility: false, fullDiskAccess: .unavailable),
            readDiskAccess: { reads += 1; return .unavailable }, openDiskSettings: { requests += 1 })
        await modernOS.refresh()
        XCTAssertEqual(modernOS.statuses["fullDiskAccess"], .unknown)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(PermissionAccess.denied.settingsStatus, .notGranted)
        XCTAssertEqual(PermissionAccess.available.settingsStatus, .granted)
    }

    func testResetPreservesLoginMirrorAndUnrelatedPreferences() throws {
        let name = "MenuBoxTests.Settings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("ko", forKey: "MacAppLibrary.language")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let store = SettingsStore(defaults: defaults)
        store.update { $0.launchAtLogin = true; $0.boxMaxColumns = 17; $0.shortcutsEnabled = false }
        store.resetToDefaults(preservingLoginItem: true)
        XCTAssertTrue(store.settings.launchAtLogin)
        XCTAssertEqual(store.settings.boxMaxColumns, AppSettings.defaults.boxMaxColumns)
        XCTAssertEqual(store.settings.shortcutsEnabled, AppSettings.defaults.shortcutsEnabled)
        XCTAssertEqual(defaults.string(forKey: "MacAppLibrary.language"), "ko")
        XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
    }
}
