// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import CoreGraphics
import Foundation
import MacAppCore

/// Pure eligibility check for an app-wide backend. Feed only resolved hosting
/// snapshots; this does not infer visibility from AX rectangle containment.
enum MenuBarSectionPlanner {
    enum Owner: Hashable {
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
        var exclusions: [Exclusion] = []

        func excluding(_ owner: Owner, reason: String) -> Plan {
            var apps = applicationKeys, systems = systemItemIDs
            if case .application(let key) = owner { apps.remove(key) }
            if case .system(let key) = owner { systems.remove(key) }
            var result = Plan(applicationKeys: apps, protectedItemsByDisplay: protectedItemsByDisplay,
                              systemItemIDs: systems, exclusions: exclusions)
            if !result.exclusions.contains(where: { $0.owner == owner }) {
                result.exclusions.append(Exclusion(owner: owner, reason: reason))
            }
            return result
        }
    }

    struct Exclusion: Equatable {
        let owner: Owner
        // Localized when presented, so app language selection applies to notices too.
        let reason: String
        var identifier: String {
            switch owner {
            case .application(let key), .system(let key): return key
            case .box, .marker: return "MenuBox"
            }
        }
    }

    /// Remove only owners whose geometry/section cannot be safely determined.
    /// Invalid displays or our own controls still invalidate the whole boundary.
    static func partialPlan(displays: [Display]) throws -> Plan {
        var excluded: [Owner: String] = [:]
        func exclude(_ item: Item, _ reason: String) {
            switch item.owner {
            case .application, .system: excluded[item.owner] = reason
            case .box, .marker: break
            }
        }
        for display in displays {
            guard let marker = display.items.first(where: { $0.owner == .marker }) else { continue }
            for item in display.items {
                if !valid(item.frame) || !display.frame.contains(item.frame) {
                    exclude(item, "The icon’s size or position could not be read.")
                }
            }
            let validItems = display.items.filter { valid($0.frame) && display.frame.contains($0.frame) }
            for (index, item) in validItems.enumerated() {
                for other in validItems.dropFirst(index + 1) where item.frame.intersects(other.frame) &&
                    item.frame.intersection(other.frame).width > 0 {
                    if item.frame.maxX <= marker.frame.minX && other.frame.maxX <= marker.frame.minX &&
                        item.owner != .box && other.owner != .box { continue }
                    exclude(item, "The icon overlaps another icon near the marker.")
                    exclude(other, "The icon overlaps another icon near the marker.")
                }
            }
        }
        func filtered() -> [Display] {
            displays.map { Display(id: $0.id, frame: $0.frame,
                items: $0.items.filter { excluded[$0.owner] == nil }, isResolved: $0.isResolved) }
        }
        while true {
            do {
                var result = try plan(displays: filtered())
                result.exclusions = excluded.map { Exclusion(owner: $0.key, reason: $0.value) }
                    .sorted { $0.identifier < $1.identifier }
                return result
            } catch Failure.applicationSpansBoundary(let key) {
                // App and system identifiers can coincide; exclude both namespaces.
                for display in displays {
                    for item in display.items where item.owner == .application(key) || item.owner == .system(key) {
                        exclude(item, "The same app or control appears on both sides of the marker.")
                    }
                }
            }
        }
    }

    enum Failure: MenuBoxLocalizedError, Equatable {
        case incompleteSnapshot
        case missingOrAmbiguousControls(String)
        case invalidItemGeometry(String)
        case ambiguousGeometry(String)
        case applicationSpansBoundary(String)

        func errorDescription(using localizer: AppLocalizer) -> String {
            switch self {
            case .incompleteSnapshot:
                return menuBoxLocalized("The menu bar layout is still updating. Try hiding the icons again.", localizer: localizer)
            case .missingOrAmbiguousControls:
                return menuBoxLocalized("MenuBox’s box or marker is missing on a display. Wait for the icons to return, then try again.", localizer: localizer)
            case .invalidItemGeometry:
                return menuBoxLocalized("Some menu bar icons have an invalid size or position. Wait for the menu bar to settle, then try again.", localizer: localizer)
            case .ambiguousGeometry:
                return menuBoxLocalized("Menu bar icons overlap at or to the right of the marker. Hold ⌘ and drag them apart, then try again.", localizer: localizer)
            case .applicationSpansBoundary(let item):
                return String(format: menuBoxLocalized("%@ appears on both sides of the marker. Place its icons on the same side on every display before hiding.", localizer: localizer), item)
            }
        }
    }

    static func plan(displays: [Display]) throws -> Plan {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count else {
            throw Failure.incompleteSnapshot
        }
        var leftApplications = Set<String>()
        var rightApplications = Set<String>()
        var protectedItems: [String: Set<String>] = [:]
        var systemItemIDs = Set<String>()
        var rightSystemItemIDs = Set<String>()

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
                throw Failure.invalidItemGeometry(display.id)
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
                    else {
                        rightSystemItemIDs.insert(key)
                        preserved.insert(item.id)
                    }
                }
            }
            protectedItems[display.id] = preserved
        }

        // Also catches different sides on different displays. The visibility
        // setting controls the whole app, so neither case permits exact hiding.
        if let conflict = leftApplications.intersection(rightApplications).sorted().first {
            throw Failure.applicationSpansBoundary(conflict)
        }
        if let conflict = systemItemIDs.intersection(rightSystemItemIDs).sorted().first {
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
