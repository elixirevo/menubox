// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import CryptoKit
import Foundation

/// Exclusion notices follow their meaning, not translated wording, display
/// names, item order or coordinates. Changing the affected set or reason resets
/// suppression; a language change alone does not.
enum HidingNoticeIdentity {
    static func partial(_ plan: MenuBarSectionPlanner.Plan) -> String {
        let entries = plan.exclusions.map { issue -> String in
            let kind: String
            switch issue.owner {
            case .application: kind = "application"
            case .system: kind = "system"
            case .box: kind = "box"
            case .marker: kind = "marker"
            }
            return encoded([kind, issue.identifier, issue.reason])
        }.sorted()
        let outcome = plan.applicationKeys.isEmpty && plan.systemItemIDs.isEmpty ? "none-hidden" : "partially-hidden"
        return digest(["exclusions", outcome] + entries)
    }

    static func message(title: String, message: String) -> String {
        digest(["message", title, message])
    }

    private static func encoded(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func digest(_ fields: [String]) -> String {
        "v1:" + SHA256.hash(data: Data(encoded(fields).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
