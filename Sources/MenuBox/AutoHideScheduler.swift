// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation

/// One countdown shared by direct menu-bar and Box interactions. Releasing the
/// last interaction always starts a full delay; elapsed time is never resumed.
final class AutoHideScheduler {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    private let schedule: Schedule
    private let canHide: () -> Bool
    private let hide: () -> Void
    private var cancellation: (() -> Void)?
    private var generation = UUID()
    private var interactions = Set<String>()
    private var delay: TimeInterval = 5
    private(set) var isArmed = false
    var isInteracting: Bool { !interactions.isEmpty }

    init(schedule: @escaping Schedule = AutoHideScheduler.timer,
         canHide: @escaping () -> Bool = { true }, hide: @escaping () -> Void) {
        self.schedule = schedule
        self.canHide = canHide
        self.hide = hide
    }

    deinit { cancellation?() }

    func arm(after delay: TimeInterval) {
        self.delay = max(0, delay)
        isArmed = true
        restart()
    }

    func cancel() {
        isArmed = false
        invalidate()
    }

    func setInteraction(_ source: String, active: Bool) {
        let changed = active ? interactions.insert(source).inserted : interactions.remove(source) != nil
        guard changed else { return }
        restart()
    }

    private func invalidate() {
        generation = UUID()
        cancellation?()
        cancellation = nil
    }

    private func restart() {
        invalidate()
        guard isArmed, !isInteracting else { return }
        let token = generation
        cancellation = schedule(delay) { [weak self] in
            guard let self, self.generation == token, self.isArmed else { return }
            self.cancellation = nil
            // The live guard refreshes interaction observation immediately before
            // hiding. A click arriving near the deadline invalidates this token.
            let ready = self.canHide()
            guard self.generation == token, self.isArmed, !self.isInteracting else { return }
            guard ready else { self.restart(); return }
            self.isArmed = false
            self.hide()
        }
    }

    private static func timer(after delay: TimeInterval, action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
