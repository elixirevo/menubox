// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import XCTest
@testable import MenuBox

final class RunningApplicationIndexTests: XCTestCase {
    private struct Entry {
        let pid: pid_t
        let bundle: String
    }

    func testDuplicatePIDsAndExitedApplicationsDoNotTrap() {
        let entries = [Entry(pid: 42, bundle: "app"), Entry(pid: 42, bundle: "app"),
                       Entry(pid: -1, bundle: "exited-one"), Entry(pid: -1, bundle: "exited-two"),
                       Entry(pid: 0, bundle: "invalid"), Entry(pid: 73, bundle: "other")]
        let result = RunningApplicationIndex.make(entries, pid: { $0.pid }, bundle: { $0.bundle })
        XCTAssertEqual(Set(result.keys), [42, 73])
        XCTAssertEqual(result[42]?.bundle, "app")
    }

    func testConflictingOwnershipCannotRouteToEitherAppRegardlessOfOrder() {
        let entries = [Entry(pid: 42, bundle: "first"), Entry(pid: 42, bundle: "second"),
                       Entry(pid: 42, bundle: "first"), Entry(pid: 73, bundle: "safe")]
        for input in [entries, entries.reversed().map { $0 }] {
            let result = RunningApplicationIndex.make(input, pid: { $0.pid }, bundle: { $0.bundle })
            XCTAssertEqual(Set(result.keys), [73])
        }
    }
}
