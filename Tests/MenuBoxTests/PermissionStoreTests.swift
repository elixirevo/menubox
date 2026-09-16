import XCTest
import Darwin
@testable import MenuBox

final class PermissionStoreTests: XCTestCase {
    private let ready = PermissionSnapshot(accessibility: true, fullDiskAccess: .available)

    func testLegacyOSDoesNotProbeOrRequireFullDiskAccess() {
        let snapshot = PermissionSnapshot.read(macOSMajorVersion: 26, accessibility: { true }, diskAccess: {
            XCTFail("macOS 26 must not access the protected preferences file")
            return .denied
        })
        XCTAssertNil(snapshot.fullDiskAccess)
        XCTAssertTrue(snapshot.isReady)
    }

    func testNativeBackendNeedsBothPermissions() {
        for (accessibility, diskAccess) in [(false, PermissionAccess.available), (true, .denied), (true, .unavailable)] {
            let snapshot = PermissionSnapshot.read(macOSMajorVersion: 27,
                accessibility: { accessibility }, diskAccess: { diskAccess })
            XCTAssertFalse(snapshot.isReady)
        }
        XCTAssertTrue(ready.isReady)
    }

    func testNewAndExistingInstallsPresentSetupAppropriately() {
        var newInstall = PermissionPromptPolicy()
        XCTAssertTrue(newInstall.shouldPresent(ready, hasSeenSetup: false))
        XCTAssertFalse(newInstall.shouldPresent(ready, hasSeenSetup: true))

        var existingInstall = PermissionPromptPolicy()
        XCTAssertFalse(existingInstall.shouldPresent(ready, hasSeenSetup: true))

        var missingOnRelaunch = PermissionPromptPolicy()
        XCTAssertTrue(missingOnRelaunch.shouldPresent(
            .init(accessibility: true, fullDiskAccess: .denied), hasSeenSetup: true))
    }

    func testClosingSetupDoesNotReopenItOnEveryPollOrPartialGrant() {
        var policy = PermissionPromptPolicy()
        let missing = PermissionSnapshot(accessibility: false, fullDiskAccess: .denied)
        XCTAssertTrue(policy.shouldPresent(missing, hasSeenSetup: true))
        XCTAssertFalse(policy.shouldPresent(missing, hasSeenSetup: true))
        XCTAssertFalse(policy.shouldPresent(.init(accessibility: true, fullDiskAccess: .denied), hasSeenSetup: true))
        XCTAssertFalse(policy.shouldPresent(ready, hasSeenSetup: true))
        XCTAssertTrue(policy.shouldPresent(.init(accessibility: false, fullDiskAccess: .available), hasSeenSetup: true))
        XCTAssertFalse(policy.shouldPresent(.init(accessibility: false, fullDiskAccess: .available), hasSeenSetup: true))
    }

    func testAnotherPermissionLossPromptsWhileOneIsStillMissing() {
        var policy = PermissionPromptPolicy()
        _ = policy.shouldPresent(.init(accessibility: false, fullDiskAccess: .available), hasSeenSetup: true)
        XCTAssertTrue(policy.shouldPresent(.init(accessibility: false, fullDiskAccess: .denied), hasSeenSetup: true))
    }

    func testOnlyActualPermissionErrorsAreReportedAsDenied() {
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .denied)
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .denied)
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .denied)
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])), .denied)
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .unavailable)
        XCTAssertEqual(FullDiskAccessProbe.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)), .unavailable)
    }

    func testProbeReadsCurrentFileWithoutDependingOnPreferenceSchema() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("An unfamiliar schema is not a permissions failure".utf8).write(to: file)
        XCTAssertEqual(FullDiskAccessProbe.read(file: file), .available)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(FullDiskAccessProbe.read(file: file), .unavailable)
    }

    func testStorePersistsFirstPresentationAndResumesOnlyAfterBothGrants() throws {
        let name = "MenuBoxTests.Permissions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var state = PermissionSnapshot(accessibility: false, fullDiskAccess: .denied)
        let store = PermissionStore(defaults: defaults, probe: { state })
        var presentations = 0, restorations = 0
        store.onNeedsSetup = { presentations += 1 }
        store.onAccessRestored = { restorations += 1 }
        store.refresh()
        store.refresh()
        XCTAssertEqual(presentations, 1)
        state = .init(accessibility: true, fullDiskAccess: .denied)
        store.refresh()
        XCTAssertEqual(restorations, 0)
        state = ready
        store.refresh()
        store.refresh()
        XCTAssertEqual(store.snapshot, ready)
        XCTAssertEqual(restorations, 1)
        let relaunched = PermissionStore(defaults: defaults, probe: { state })
        relaunched.onNeedsSetup = { XCTFail("Ready returning users should not see setup again") }
        relaunched.refresh()
        state = .init(accessibility: true, fullDiskAccess: .denied)
        store.refresh()
        store.refresh()
        XCTAssertEqual(presentations, 2)
    }
}
