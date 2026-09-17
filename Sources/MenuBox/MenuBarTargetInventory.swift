import AppKit
import ApplicationServices

/// Coordinates are routing data, not identity: overflow items share rectangles.
struct MenuBarTargetIdentity: Hashable, @unchecked Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let identifier: String
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.processIdentifier == rhs.processIdentifier,
              lhs.bundleIdentifier == rhs.bundleIdentifier else { return false }
        if !lhs.identifier.isEmpty || !rhs.identifier.isEmpty {
            return !lhs.identifier.isEmpty && lhs.identifier == rhs.identifier
        }
        return CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(processIdentifier)
        hasher.combine(bundleIdentifier)
        hasher.combine(identifier)
        if identifier.isEmpty { hasher.combine(CFHash(element)) }
    }
}

struct MenuBarTargetInventory {
    private(set) var targets: [MenuBarProxyTarget] = []
    private var missingObservations: [MenuBarTargetIdentity: Int] = [:]

    mutating func merge(_ incoming: [MenuBarProxyTarget], runningOwners: [pid_t: String],
                        completeOwners: Set<pid_t>, preservingApplications: Set<String>) {
        let live = incoming.filter { runningOwners[$0.processIdentifier] == $0.bundleIdentifier }
        let found = Set(live.map(\.identity))
        targets.removeAll { target in
            guard runningOwners[target.processIdentifier] == target.bundleIdentifier else { return true }
            if found.contains(target.identity) {
                missingObservations[target.identity] = nil
            } else if completeOwners.contains(target.processIdentifier),
                      !preservingApplications.contains(target.bundleIdentifier) {
                missingObservations[target.identity, default: 0] += 1
                return missingObservations[target.identity, default: 0] >= 2
            } else {
                missingObservations[target.identity] = nil
            }
            return false
        }
        // Keep a stable Box order through collapsed/hidden placeholder positions.
        for target in live {
            if let index = targets.firstIndex(where: { $0.identity == target.identity }) {
                targets[index] = target
            } else {
                targets.append(target)
            }
        }
        let retained = Set(targets.map(\.identity))
        missingObservations = missingObservations.filter { retained.contains($0.key) }
    }

    mutating func remove(processIdentifier: pid_t) {
        targets.removeAll { $0.processIdentifier == processIdentifier }
        missingObservations = missingObservations.filter { $0.key.processIdentifier != processIdentifier }
    }

    func selected(applications: Set<String>) -> [MenuBarProxyTarget] {
        targets.filter { applications.contains($0.bundleIdentifier) }
    }

}
