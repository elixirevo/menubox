// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation
import MacAppCore

func menuBoxLocalized(_ key: String, localizer: AppLocalizer = .current) -> String {
    localizer.string(key, bundle: .module)
}

/// Error descriptions share the same app language as settings, menus and alerts.
protocol MenuBoxLocalizedError: LocalizedError {
    func errorDescription(using localizer: AppLocalizer) -> String
}

extension MenuBoxLocalizedError {
    var errorDescription: String? { errorDescription(using: .current) }
}
