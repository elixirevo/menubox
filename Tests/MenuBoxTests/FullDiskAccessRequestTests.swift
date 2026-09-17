import XCTest
@testable import MenuBox

final class FullDiskAccessRequestTests: XCTestCase {
    func testRegistersBeforeOpeningSettingsWhenAccessIsNeededOrUnknown() {
        for access in [PermissionAccess.denied, .unavailable] {
            var events: [String] = []
            FullDiskAccessRequest.perform(access: access, register: {
                events.append("register")
            }, openSettings: {
                events.append("open")
            })
            XCTAssertEqual(events, ["register", "open"])
        }
    }

    func testDenialAndMissingDirectoryStillOpenSettings() {
        for code in [NSFileReadNoPermissionError, NSFileNoSuchFileError] {
            var didOpen = false
            FullDiskAccessRequest.perform(access: .denied, register: {
                throw NSError(domain: NSCocoaErrorDomain, code: code)
            }, openSettings: {
                didOpen = true
            })
            XCTAssertTrue(didOpen)
        }
    }

    func testAlreadyGrantedAccessDoesNotReadUnrelatedDirectory() {
        var didOpen = false
        FullDiskAccessRequest.perform(access: .available, register: {
            XCTFail("Do not attempt registration when access is already available")
        }, openSettings: {
            didOpen = true
        })
        XCTAssertTrue(didOpen)
    }

    func testHelperReceivesOnlyRegistrationArgument() throws {
        try withExecutable("[ \"$#\" -eq 1 ] && [ \"$1\" = \"--menubox-register-full-disk-access\" ]") { executable in
            XCTAssertNoThrow(try FullDiskAccessRequest.registerUsingHelper(executableURL: executable))
        }
    }

    func testHelperFailureIsReported() throws {
        try withExecutable("exit 7") { executable in
            XCTAssertThrowsError(try FullDiskAccessRequest.registerUsingHelper(executableURL: executable)) {
                XCTAssertEqual($0 as? FullDiskAccessRequest.Failure, .helperFailed(7))
            }
        }
        XCTAssertThrowsError(try FullDiskAccessRequest.registerUsingHelper(executableURL: nil)) {
            XCTAssertEqual($0 as? FullDiskAccessRequest.Failure, .missingExecutable)
        }
    }

    func testStalledHelperCannotBlockSettingsIndefinitely() throws {
        try withExecutable("exec /bin/sleep 30") { executable in
            XCTAssertThrowsError(try FullDiskAccessRequest.registerUsingHelper(executableURL: executable, timeout: 0.1)) {
                XCTAssertEqual($0 as? FullDiskAccessRequest.Failure, .timedOut)
            }
        }
    }

    private func withExecutable(_ script: String, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("registration-helper")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(executable)
    }
}
