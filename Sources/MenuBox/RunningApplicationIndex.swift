import Foundation

/// Process lists are observations, not a guarantee of unique, live PIDs.
/// Conflicting ownership is omitted so callers cannot route or hide the wrong app.
enum RunningApplicationIndex {
    static func make<Element>(_ elements: [Element], pid: (Element) -> pid_t,
                              bundle: (Element) -> String) -> [pid_t: Element] {
        var result: [pid_t: Element] = [:]
        var ambiguous = Set<pid_t>()
        for element in elements {
            let identifier = pid(element)
            guard identifier > 0, !ambiguous.contains(identifier) else { continue }
            if let existing = result[identifier] {
                if bundle(existing) != bundle(element) {
                    result.removeValue(forKey: identifier)
                    ambiguous.insert(identifier)
                }
            } else {
                result[identifier] = element
            }
        }
        return result
    }
}
