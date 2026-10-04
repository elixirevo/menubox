// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import MacAppOnboarding

/// No services, menus, hotkeys or background work until the current terms are accepted.
@MainActor
final class MenuBoxLaunchGate {
    let agreement: TermsAgreementModel
    private(set) var hasStarted = false

    init(agreement: TermsAgreementModel) { self.agreement = agreement }

    @discardableResult
    func startIfAllowed(_ start: () -> Void) -> Bool {
        guard agreement.allowsAppUse else { return false }
        guard !hasStarted else { return true }
        hasStarted = true
        start()
        return true
    }
}
