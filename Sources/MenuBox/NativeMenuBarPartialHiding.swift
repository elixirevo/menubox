// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import MacAppCore

extension NativeMenuBarHiding {
    enum HelperFailure: MenuBoxLocalizedError {
        case unavailable
        func errorDescription(using localizer: AppLocalizer) -> String {
            menuBoxLocalized("The icon recovery helper could not start. Restart MenuBox and check its menu bar permissions.", localizer: localizer)
        }
    }

    /// Validate the whole remaining set repeatedly: removing one helper can make
    /// another helper of the same owner unsafe to hide. No preference writes here.
    static func eligiblePlan(_ snapshot: NativeMenuBarSnapshot, _ requested: MenuBarSectionPlanner.Plan,
                             document: NativeMenuBarPreferences.Document,
                             validateSystem: (String) throws -> Void) throws -> MenuBarSectionPlanner.Plan {
        var plan = requested
        let visible = Set(snapshot.bars.flatMap(\.items).map(\.bundle))
        while !plan.applicationKeys.isEmpty {
            do {
                _ = try NativeMenuBarPreferences.controlKeys(for: plan.applicationKeys, visible: visible,
                    executables: snapshot.executables, in: document)
                break
            } catch let error as NativeMenuBarPreferences.Failure {
                let app: String, reason: String
                switch error {
                case .missing(let key): (app, reason) = (key, "No menu bar setting was found for this app.")
                case .ambiguous(let key): (app, reason) = (key, "More than one setting controls this icon.")
                case .disabled(let key): (app, reason) = (key, "macOS already marks this icon as disabled, but it is still visible.")
                case .shared(let key): (app, reason) = (key, "Changing this setting would also affect icons that must stay visible.")
                default: throw error
                }
                guard plan.applicationKeys.contains(app) else { throw error }
                plan = plan.excluding(.application(app), reason: reason)
            }
        }
        for item in plan.systemItemIDs.sorted() {
            do { try validateSystem(item) }
            catch NativeSystemMenuBarPreferences.Failure.unsupported {
                plan = plan.excluding(.system(item), reason: "This macOS control does not have a supported hiding setting.")
            } catch NativeSystemMenuBarPreferences.Failure.schema {
                plan = plan.excluding(.system(item), reason: "This macOS control’s setting has an unsupported format.")
            }
        }
        return plan
    }

    static func preparePartialPlan(_ snapshot: NativeMenuBarSnapshot,
                                   _ plan: MenuBarSectionPlanner.Plan) throws -> MenuBarSectionPlanner.Plan {
        let current = try NativeMenuBarPreferences().read()
        // Eligibility expects the user's original flags, including during an
        // extension of a hidden transaction. Reconstruct them without revealing.
        let original: NativeMenuBarPreferences.Document
        if NativeMenuBarRecovery.hasPending {
            let journal = try NativeMenuBarRecovery.decodedJournal(Data(contentsOf: NativeMenuBarRecovery.journalURL))
            original = try NativeMenuBarPreferences.decode(NativeMenuBarRecovery.restorationData(journal, current: current))
        } else { original = current }
        return try eligiblePlan(snapshot, plan, document: original) { _ = try NativeSystemMenuBarPreferences.prepare([$0]) }
    }

    static func partialMessage(_ plan: MenuBarSectionPlanner.Plan, localizer: AppLocalizer = .current) -> String? {
        guard !plan.exclusions.isEmpty else { return nil }
        let groups = Dictionary(grouping: plan.exclusions, by: \.reason)
        let details = groups.sorted { lhs, rhs in
            let left = lhs.value.map(\.identifier).sorted().joined(separator: ",")
            let right = rhs.value.map(\.identifier).sorted().joined(separator: ",")
            return left == right ? lhs.key < rhs.key : left < right
        }.map { reason, issues in
            let names = issues.sorted { $0.identifier < $1.identifier }.map { issue -> String in
                if case .application(let bundle) = issue.owner {
                    return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle }?.localizedName ?? bundle
                }
                return NativeSystemMenuBarPreferences.displayName(for: issue.identifier, localizer: localizer)
            }
            let explanation = reason == "This macOS control does not have a supported hiding setting."
                ? "Hiding is not supported yet." : reason
            return names.joined(separator: ", ") + ": " + menuBoxLocalized(explanation, localizer: localizer)
        }
        let summary = plan.applicationKeys.isEmpty && plan.systemItemIDs.isEmpty
            ? "No icons were hidden." : "Other icons remain hidden."
        return (details + [menuBoxLocalized(summary, localizer: localizer)]).joined(separator: "\n")
    }
}
