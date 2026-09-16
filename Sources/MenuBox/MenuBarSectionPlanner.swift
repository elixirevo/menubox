import CoreGraphics
import Foundation

/// Pure eligibility check for an app-wide backend. Feed only resolved hosting
/// snapshots; this does not infer visibility from AX rectangle containment.
enum MenuBarSectionPlanner {
    enum Owner: Equatable {
        case box
        case marker
        case application(String) // Backend control key, including helper attribution.
        case system(String)
    }

    struct Item {
        let id: String
        let owner: Owner
        let frame: CGRect
    }

    struct Display {
        let id: String
        let frame: CGRect
        let items: [Item]
        let isResolved: Bool
    }

    struct Plan: Equatable {
        let applicationKeys: Set<String>
        let protectedItemsByDisplay: [String: Set<String>]
        let systemItemIDs: Set<String>
    }

    enum Failure: Error, Equatable {
        case incompleteSnapshot
        case missingOrAmbiguousControls(String)
        case ambiguousGeometry(String)
        case applicationSpansBoundary(String)
    }

    static func plan(displays: [Display]) throws -> Plan {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count else {
            throw Failure.incompleteSnapshot
        }
        var leftApplications = Set<String>()
        var rightApplications = Set<String>()
        var protectedItems: [String: Set<String>] = [:]
        var systemItemIDs = Set<String>()

        for display in displays {
            guard display.isResolved, valid(display.frame),
                  !display.id.isEmpty,
                  display.items.allSatisfy({ !$0.id.isEmpty }),
                  Set(display.items.map(\.id)).count == display.items.count else {
                throw Failure.incompleteSnapshot
            }
            let markers = display.items.filter { $0.owner == .marker }
            let boxes = display.items.filter { $0.owner == .box }
            guard markers.count == 1, boxes.count == 1 else {
                throw Failure.missingOrAmbiguousControls(display.id)
            }
            let items = display.items.sorted { $0.frame.minX < $1.frame.minX }
            guard items.allSatisfy({ valid($0.frame) && display.frame.contains($0.frame) }) else {
                throw Failure.ambiguousGeometry(display.id)
            }

            let boundary = markers[0].frame.minX
            // On a notched display, macOS places overflow items at the same
            // placeholder coordinates. Their ordering is unknown, but their
            // membership is still unambiguous when wholly left of the marker.
            for (index, item) in items.enumerated() {
                for other in items.dropFirst(index + 1) where item.frame.intersects(other.frame) &&
                    item.frame.intersection(other.frame).width > 0 {
                    let containsControl = [item.owner, other.owner].contains(.box) ||
                        [item.owner, other.owner].contains(.marker)
                    guard !containsControl, item.frame.maxX <= boundary, other.frame.maxX <= boundary else {
                        throw Failure.ambiguousGeometry(display.id)
                    }
                }
                if item.owner != .marker && item.owner != .box {
                    guard item.frame.maxX <= boundary || item.frame.minX >= markers[0].frame.maxX else {
                        throw Failure.ambiguousGeometry(display.id)
                    }
                }
            }
            var preserved = Set<String>()
            for item in items {
                switch item.owner {
                case .box, .marker:
                    preserved.insert(item.id)
                case .application(let key):
                    guard !key.isEmpty else { throw Failure.incompleteSnapshot }
                    if item.frame.maxX <= boundary {
                        leftApplications.insert(key)
                    } else {
                        rightApplications.insert(key)
                        preserved.insert(item.id)
                    }
                case .system(let key):
                    if item.frame.maxX <= boundary { systemItemIDs.insert(key) }
                    else { preserved.insert(item.id) }
                }
            }
            protectedItems[display.id] = preserved
        }

        // Also catches different sides on different displays. The visibility
        // setting controls the whole app, so neither case permits exact hiding.
        if let conflict = leftApplications.intersection(rightApplications).sorted().first {
            throw Failure.applicationSpansBoundary(conflict)
        }
        return Plan(applicationKeys: leftApplications, protectedItemsByDisplay: protectedItems,
                    systemItemIDs: systemItemIDs)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}
