import CoreGraphics
import Foundation

/// Debounce missing MenuBox hosts, not differences in other apps' visibility.
/// A single incomplete AX read or a normal marker collapse is not a repair.
struct StatusItemReplicaRecovery {
    private var previousMissing = Set<String>()
    private var lastRepair: TimeInterval = -.infinity
    private var previousMarkerHidden: Bool?

    mutating func resetObservation() {
        previousMissing = []
        previousMarkerHidden = nil
    }

    mutating func shouldRepair(bars: [NativeMenuBarSnapshot.Bar], markerHidden: Bool,
                               now: TimeInterval) -> Bool {
        guard !bars.isEmpty else {
            resetObservation()
            return false
        }
        if previousMarkerHidden != markerHidden { previousMissing = [] }
        previousMarkerHidden = markerHidden
        let expected = markerHidden ? 1 : 2
        let missing = Set(bars.filter { bar in
            let own = bar.items.filter {
                $0.bundle == NativeMenuBarPreferences.ownBundle &&
                    (!markerHidden || $0.frame.width > StatusItemMarkerPresentation.collapsedHostWidth)
            }
            return own.count < expected
        }.map(\.id))
        defer { previousMissing = missing }
        guard !missing.isEmpty, missing == previousMissing, now - lastRepair >= 30 else { return false }
        lastRepair = now
        return true
    }
}
