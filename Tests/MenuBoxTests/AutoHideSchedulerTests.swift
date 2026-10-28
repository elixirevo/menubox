// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import XCTest
@testable import MenuBox

final class AutoHideSchedulerTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 0
        var jobs: [(id: UUID, at: TimeInterval, action: () -> Void)] = []
        var cancelled = Set<UUID>()
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let id = UUID()
            jobs.append((id, now + delay, action))
            return { self.cancelled.insert(id) }
        }
        func advance(_ interval: TimeInterval) {
            now += interval
            let due = jobs.filter { $0.at <= now }
            jobs.removeAll { $0.at <= now }
            for job in due where !cancelled.contains(job.id) { job.action() }
        }
        var pending: Int { jobs.filter { !cancelled.contains($0.id) }.count }
    }

    func testMenuPausesPastOriginalDeadlineAndGetsFullDelayAfterClose() {
        let clock = Clock()
        var hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        timer.arm(after: 5)
        clock.advance(4)
        timer.setInteraction("menu", active: true)
        clock.advance(30)
        XCTAssertEqual(hidden, 0)
        timer.setInteraction("menu", active: false)
        clock.advance(4.9)
        XCTAssertEqual(hidden, 0)
        clock.advance(0.1)
        XCTAssertEqual(hidden, 1)
        XCTAssertFalse(timer.isArmed)
    }

    func testDragAndSubmenuMustBothEndBeforeCountdown() {
        let clock = Clock()
        var hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        timer.arm(after: 3)
        timer.setInteraction("pointer", active: true)
        timer.setInteraction("box-menu", active: true)
        timer.setInteraction("pointer", active: false)
        clock.advance(10)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(clock.pending, 0)
        timer.setInteraction("box-menu", active: false)
        clock.advance(3)
        XCTAssertEqual(hidden, 1)
    }

    func testRepeatedObservationDoesNotKeepRestartingCountdown() {
        let clock = Clock()
        var hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        timer.arm(after: 5)
        timer.setInteraction("menu", active: true)
        timer.setInteraction("menu", active: false)
        clock.advance(4)
        timer.setInteraction("menu", active: false)
        clock.advance(1)
        XCTAssertEqual(hidden, 1)
    }

    func testSettingsChangeWhilePausedUsesNewFullDelay() {
        let clock = Clock()
        var hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        timer.arm(after: 5)
        timer.setInteraction("menu", active: true)
        timer.arm(after: 10)
        clock.advance(100)
        XCTAssertEqual(hidden, 0)
        timer.setInteraction("menu", active: false)
        clock.advance(9)
        XCTAssertEqual(hidden, 0)
        clock.advance(1)
        XCTAssertEqual(hidden, 1)
    }

    func testExplicitHideStopOrDisableCannotBeRearmedByLateMenuClose() {
        let clock = Clock()
        var hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        timer.arm(after: 5)
        let stale = clock.jobs[0].action
        timer.setInteraction("menu", active: true)
        timer.cancel()
        timer.setInteraction("menu", active: false)
        stale()
        clock.advance(100)
        XCTAssertEqual(hidden, 0)
        XCTAssertFalse(timer.isArmed)
        timer.arm(after: 5)
        clock.advance(5)
        XCTAssertEqual(hidden, 1)
    }

    func testPressDetectedAtDeadlineInvalidatesTheAlreadyFiringTimer() {
        let clock = Clock()
        var hidden = 0, checkPress = true
        var timer: AutoHideScheduler!
        timer = AutoHideScheduler(schedule: clock.schedule, canHide: {
            if checkPress { timer.setInteraction("pointer", active: true) }
            return true
        }, hide: { hidden += 1 })
        timer.arm(after: 5)
        clock.advance(5)
        XCTAssertEqual(hidden, 0)
        checkPress = false
        timer.setInteraction("pointer", active: false)
        clock.advance(5)
        XCTAssertEqual(hidden, 1)
    }

    func testPendingRestorationRetriesInsteadOfLosingAutoHide() {
        let clock = Clock()
        var ready = false, hidden = 0
        let timer = AutoHideScheduler(schedule: clock.schedule, canHide: { ready }, hide: { hidden += 1 })
        timer.arm(after: 5)
        clock.advance(5)
        XCTAssertEqual(hidden, 0)
        XCTAssertTrue(timer.isArmed)
        ready = true
        clock.advance(5)
        XCTAssertEqual(hidden, 1)
    }

    @MainActor
    func testBoxMenuLifecyclePausesSchedulerAndCloseReleasesItOnce() throws {
        let suite = "MenuBox.auto-hide-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = BoxWindowController(settingsStore: SettingsStore(defaults: defaults))
        let clock = Clock()
        var hidden = 0, starts = 0, ends = 0
        let timer = AutoHideScheduler(schedule: clock.schedule) { hidden += 1 }
        box.onMenuInteractionStarted = {
            starts += 1
            timer.setInteraction("box-menu", active: true)
        }
        box.onMenuInteractionEnded = {
            ends += 1
            timer.setInteraction("box-menu", active: false)
        }
        timer.arm(after: 5)
        box.beginMenuInteraction()
        box.beginMenuInteraction()
        clock.advance(30)
        XCTAssertEqual(hidden, 0)
        box.close()
        box.endMenuInteraction()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        clock.advance(4)
        XCTAssertEqual(hidden, 0)
        clock.advance(1)
        XCTAssertEqual(hidden, 1)
    }
}
