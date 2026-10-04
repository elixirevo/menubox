// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import CoreGraphics
import Foundation

/// Debounce missing hosts and missing control identities independently. Refresh
/// identifiers in place before re-registering intact hosts to preserve ordering.
struct StatusItemReplicaRecovery {
    enum Repair: Equatable { case refreshIdentifiers, reregisterItems }
    private enum Issue: Equatable {
        case missing(Set<String>)
        case unidentified(Set<String>)
    }
    private var previousIssue: Issue?
    private var refreshedIdentifiers = false
    private var lastRepair: TimeInterval = -.infinity
    private var previousMarkerHidden: Bool?

    mutating func resetObservation() {
        previousIssue = nil
        refreshedIdentifiers = false
        previousMarkerHidden = nil
    }

    mutating func repair(bars: [NativeMenuBarSnapshot.Bar], markerHidden: Bool,
                         now: TimeInterval) -> Repair? {
        guard !bars.isEmpty else {
            resetObservation()
            return nil
        }
        if previousMarkerHidden != markerHidden { resetObservation() }
        previousMarkerHidden = markerHidden
        let expected = markerHidden ? 1 : 2
        let counts = bars.map { bar in
            bar.items.filter {
                $0.bundle == NativeMenuBarPreferences.ownBundle &&
                    (!markerHidden || $0.frame.width > StatusItemMarkerPresentation.collapsedHostWidth)
            }.count
        }
        let missing = Set(zip(bars, counts).filter { $0.1 < expected }.map { $0.0.id })
        let issue: Issue?
        if !missing.isEmpty {
            issue = .missing(missing)
        } else if counts.allSatisfy({ $0 == expected }) {
            do {
                _ = try NativeMenuBarSnapshot.controlOrder(in: bars, markerHidden: markerHidden)
                // Partial identity can resolve an expanded pair, but the Box
                // must stay identifiable after the marker host disappears.
                let hasBoxIdentifier = bars.contains { bar in
                    bar.items.contains { $0.bundle == NativeMenuBarPreferences.ownBundle &&
                        $0.identifier == "MenuBox.main" }
                }
                issue = hasBoxIdentifier ? nil : .unidentified(Set(bars.map(\.id)))
            } catch NativeMenuBarSnapshot.Failure.incomplete {
                issue = .unidentified(Set(bars.map(\.id)))
            } catch {
                // Contradictory identities or a user-reordered boundary need
                // validation, not repeated removal and recreation of controls.
                issue = nil
            }
        } else {
            issue = nil
        }
        if issue != previousIssue { refreshedIdentifiers = false }
        defer { previousIssue = issue }
        guard let issue, issue == previousIssue, now - lastRepair >= 30 else { return nil }
        lastRepair = now
        if case .unidentified = issue, !refreshedIdentifiers {
            refreshedIdentifiers = true
            return .refreshIdentifiers
        }
        refreshedIdentifiers = false
        return .reregisterItems
    }
}
