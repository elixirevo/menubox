import AppKit
import ApplicationServices

struct NativeMenuBarSnapshot {
    struct Item {
        var id: String
        let bundle: String
        let frame: CGRect
        let identifier: String
        var isTransientSystemIndicator: Bool {
            bundle == "com.apple.MenuBarAgent" &&
                ["plus", "com.apple.menuextra.audiovideo"].contains(identifier)
        }
    }
    struct Bar {
        let frame: CGRect
        var items: [Item]
        var id: String { "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)" }
    }
    let bars: [Bar]
    let executables: [String: URL]
    var applicationControlBundles: Set<String> = []

    enum Failure: LocalizedError {
        case permission, incomplete, boundary, verification
        var errorDescription: String? {
            switch self {
            case .permission: return "MenuBox needs Device Control and Data Access permission."
            case .incomplete: return "The menu bar layout is not ready. Please try again."
            case .boundary: return "The marker boundary differs between displays or cannot be resolved."
            case .verification: return "The menu bar did not match the requested hiding result. The icons were restored."
            }
        }
    }

    static func capture(markerHidden: Bool = false) throws -> NativeMenuBarSnapshot {
        let raw = try captureUnresolved()
        let document = try NativeMenuBarPreferences().read()
        return NativeMenuBarSnapshot(bars: try resolveControls(raw.bars, markerHidden: markerHidden),
            executables: raw.executables, applicationControlBundles: NativeMenuBarPreferences.applicationControlBundles(
                Set(raw.bars.flatMap(\.items).map(\.bundle)), executables: raw.executables, in: document))
    }

    /// Keep raw host membership available for repairing missing local replicas.
    static func captureUnresolved() throws -> NativeMenuBarSnapshot {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            throw Failure.incomplete
        }
        let running = NSWorkspace.shared.runningApplications
        // Read identity once before indexing: NSRunningApplication properties
        // can change as another process exits during this scan.
        let identities = running.map { (pid: $0.processIdentifier, bundle: $0.bundleIdentifier ?? "") }
        let bundles = RunningApplicationIndex.make(identities, pid: { $0.pid }, bundle: { $0.bundle })
            .mapValues(\.bundle)
        var executables: [String: URL] = [:]
        for app in running {
            if let bundle = app.bundleIdentifier, let url = app.executableURL { executables[bundle] = url }
        }
        var byFrame: [String: Bar] = [:]
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        for window in children(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute as String) {
            guard let frame = rect(window), isMenuBar(frame, on: displays) else { continue }
            var items: [Item] = []
            for group in children(window) {
                guard let frame = rect(group) else { continue }
                for hosted in children(group) {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(hosted, &pid) == .success,
                          let bundle = bundles[pid], !bundle.isEmpty else { throw Failure.incomplete }
                    items.append(Item(id: "", bundle: bundle, frame: frame,
                                      identifier: identifier(hosted, agentPID: agent.processIdentifier)))
                }
            }
            items.sort { $0.frame.minX < $1.frame.minX }
            var counts: [String: Int] = [:]
            for index in items.indices {
                let item = items[index]
                let ordinal = counts[item.bundle, default: 0]
                counts[item.bundle] = ordinal + 1
                items[index].id = item.identifier.isEmpty ? "\(item.bundle):\(ordinal)" : "\(item.bundle):\(item.identifier)"
            }
            let bar = Bar(frame: frame, items: items)
            let old = byFrame[bar.id]
            if old == nil || items.filter({ !$0.identifier.isEmpty }).count > old!.items.filter({ !$0.identifier.isEmpty }).count {
                byFrame[bar.id] = bar
            }
        }
        return NativeMenuBarSnapshot(bars: Array(byFrame.values), executables: executables)
    }

    /// MenuBarAgent also publishes popups and can retain disconnected display
    /// windows. Neither is a screen whose marker boundary should be planned.
    static func isMenuBar(_ frame: CGRect, on displays: [CGRect]) -> Bool {
        frame.height >= 18 && frame.height <= 60 && displays.contains { display in
            abs(frame.minX - display.minX) <= 1 && abs(frame.minY - display.minY) <= 1 &&
                abs(frame.width - display.width) <= 1
        }
    }

    static func resolveControls(_ captured: [Bar], markerHidden: Bool) throws -> [Bar] {
        let reference = try controlOrder(in: captured, markerHidden: markerHidden)
        var bars = captured.sorted { $0.frame.minX < $1.frame.minX }
        if markerHidden {
            for index in bars.indices {
                // Inactive display replicas may omit the AX identifier. Only
                // MenuBox's collapsed host is excluded; never a full-size marker
                // or another app's narrow icon. The Box must still be resolved.
                bars[index].items.removeAll {
                    $0.bundle == NativeMenuBarPreferences.ownBundle &&
                        ($0.identifier.isEmpty || $0.identifier == "MenuBox.marker") &&
                        $0.frame.width >= 0 && $0.frame.width <= StatusItemMarkerPresentation.collapsedHostWidth
                }
            }
        }
        for index in bars.indices {
            let own = bars[index].items.indices.filter { bars[index].items[$0].bundle == NativeMenuBarPreferences.ownBundle }
            guard own.count == (markerHidden ? 1 : 2) else { throw Failure.incomplete }
            // Replica AX buttons can omit identifiers. Their order within this
            // app is shared, but their distance from the display edge is not:
            // other apps and system controls can differ between displays.
            let ordered = own.sorted { bars[index].items[$0].frame.minX < bars[index].items[$1].frame.minX }
            for (ordinal, itemIndex) in ordered.enumerated() {
                let item = bars[index].items[itemIndex]
                let identity = reference[ordinal]
                guard item.identifier.isEmpty || item.identifier == identity,
                      item.frame.width > 0, bars[index].frame.contains(item.frame),
                      ordinal == 0 || bars[index].items[ordered[ordinal - 1]].frame.maxX <= item.frame.minX
                else { throw Failure.boundary }
                bars[index].items[itemIndex].id = identity
            }
            guard Set(bars[index].items.map(\.id)).count == bars[index].items.count else { throw Failure.incomplete }
        }
        if !markerHidden, bars.contains(where: { bar in
            bar.items.contains { $0.id == "MenuBox.marker" && $0.frame.width <= StatusItemMarkerPresentation.collapsedHostWidth }
        }) { throw Failure.incomplete }
        return bars
    }

    /// MenuBarAgent can lose one identifier after restarting. With exactly two
    /// own hosts, either identifier uniquely identifies the other host. Require
    /// agreement across displays; never assume that the marker is on the left.
    static func controlOrder(in bars: [Bar], markerHidden: Bool) throws -> [String] {
        var reference: [String]?
        for bar in bars {
            let hosted = bar.items.filter { $0.bundle == NativeMenuBarPreferences.ownBundle }
            let own = hosted.filter {
                $0.bundle == NativeMenuBarPreferences.ownBundle &&
                    !(markerHidden && ($0.identifier.isEmpty || $0.identifier == "MenuBox.marker") &&
                      $0.frame.width >= 0 && $0.frame.width <= StatusItemMarkerPresentation.collapsedHostWidth)
            }.sorted { $0.frame.minX < $1.frame.minX }
            guard own.count == (markerHidden ? 1 : 2) else { continue }
            var order = own.map(\.identifier)
            // A positively identified collapsed marker also identifies the
            // other, full-size host as the Box. A lone blank host cannot do so.
            if markerHidden, order == [""], hosted.count == 2,
               own[0].frame.width > StatusItemMarkerPresentation.collapsedHostWidth,
               hosted.contains(where: { $0.identifier == "MenuBox.marker" && $0.frame.width >= 0 &&
                   $0.frame.width <= StatusItemMarkerPresentation.collapsedHostWidth }) {
                order = ["MenuBox.main"]
            }
            let identified = order.filter { !$0.isEmpty }
            guard identified.allSatisfy({ ["MenuBox.main", "MenuBox.marker"].contains($0) }),
                  Set(identified).count == identified.count else { throw Failure.boundary }
            guard !identified.isEmpty else { continue }
            if markerHidden {
                guard order == ["MenuBox.main"] else { throw Failure.boundary }
            } else if let missing = order.firstIndex(of: "") {
                order[missing] = identified[0] == "MenuBox.main" ? "MenuBox.marker" : "MenuBox.main"
            }
            guard reference == nil || reference == order else { throw Failure.boundary }
            reference = order
        }
        guard let reference else { throw Failure.incomplete }
        return reference
    }

    func plan() throws -> MenuBarSectionPlanner.Plan {
        guard !bars.isEmpty else { throw Failure.incomplete }
        // Validate each display's boundary directly. A fully expanded external
        // reference display is not required for a laptop-only overflow layout.
        let displays = bars.map { bar -> MenuBarSectionPlanner.Display in
            // Temporary OS activity indicators have no per-control visibility
            // preference. Preserve them without blocking the user's app section.
            let items = bar.items.filter { !$0.isTransientSystemIndicator }.map { item -> MenuBarSectionPlanner.Item in
                let owner: MenuBarSectionPlanner.Owner
                if item.id == "MenuBox.main" { owner = .box }
                else if item.id == "MenuBox.marker" { owner = .marker }
                else if usesSystemControl(item) { owner = .system(item.id) }
                else { owner = .application(item.bundle) }
                return .init(id: item.id, owner: owner, frame: item.frame)
            }
            return .init(id: bar.id, frame: bar.frame, items: items, isResolved: true)
        }
        return try MenuBarSectionPlanner.plan(displays: displays)
    }

    /// Manufacturer is not a capability. Independently owned app records take
    /// the common path; only shared hosts and known control adapters are special.
    /// Unknown standalone apps still use common ownership validation, which
    /// retries missing records and refuses ambiguous/collateral writes.
    private func usesSystemControl(_ item: Item) -> Bool {
        if NativeMenuBarPreferences.sharedSystemHosts.contains(item.bundle) { return true }
        if applicationControlBundles.contains(item.bundle) { return false }
        return NativeSystemMenuBarPreferences.Setting.allCases.contains { $0.itemID == item.id }
    }

    func verifyHidden(_ applications: Set<String>, comparedTo before: NativeMenuBarSnapshot,
                      markerHidden: Bool = false, systemItems: Set<String> = []) throws {
        guard Set(bars.map(\.id)) == Set(before.bars.map(\.id)) else { throw Failure.verification }
        for old in before.bars {
            guard let current = bars.first(where: { $0.id == old.id }),
                  !current.items.contains(where: { applications.contains($0.bundle) || systemItems.contains($0.id) }) else {
                throw Failure.verification
            }
            if markerHidden, current.items.contains(where: { $0.id == "MenuBox.marker" }) { throw Failure.verification }
            // MenuBarAgent's transient '+' indicator appears during computer
            // use and shifts neighboring items. Compare protected identities
            // and their order, rather than freezing global x coordinates.
            let protected = old.items.filter {
                !applications.contains($0.bundle) && !systemItems.contains($0.id) &&
                    !(markerHidden && $0.id == "MenuBox.marker") &&
                    !$0.isTransientSystemIndicator
            }.sorted { $0.frame.minX < $1.frame.minX }
            var previousEnd: CGFloat?
            for item in protected {
                guard let actual = current.items.first(where: { $0.id == item.id }),
                      current.frame.contains(actual.frame),
                      actual.frame.width > 0,
                      previousEnd.map({ $0 <= actual.frame.minX + 1 }) ?? true else { throw Failure.verification }
                previousEnd = actual.frame.maxX
            }
        }
    }

    enum HiddenState { case hidden, targetsVisible, layoutChanged }

    var membershipSignature: String {
        bars.map { bar in
            bar.id + ":" + bar.items.filter { !$0.isTransientSystemIndicator }.map(\.id).sorted().joined(separator: ",")
        }.sorted().joined(separator: ";")
    }

    struct HiddenSectionUpdate {
        let baseline: NativeMenuBarSnapshot
        let plan: MenuBarSectionPlanner.Plan
    }

    /// Locate additions relative to an original right-side neighbor while the
    /// marker and selected items remain absent. Historical hidden items are
    /// retained for ownership/recovery checks, never used as live click frames.
    func addingItemsWhileHidden(comparedTo before: NativeMenuBarSnapshot,
                                boundaryReference: NativeMenuBarSnapshot,
                                plan: MenuBarSectionPlanner.Plan) throws -> HiddenSectionUpdate {
        try verifyHidden(plan.applicationKeys, comparedTo: before, markerHidden: true,
                         systemItems: plan.systemItemIDs)
        guard Set(bars.map(\.id)) == Set(boundaryReference.bars.map(\.id)),
              !bars.isEmpty else { throw Failure.incomplete }
        var leftApps = Set<String>(), rightApps = Set<String>(), leftSystems = Set<String>(), rightSystems = Set<String>()
        var updatedBars: [Bar] = []
        for current in bars {
            guard let old = before.bars.first(where: { $0.id == current.id }),
                  let reference = boundaryReference.bars.first(where: { $0.id == current.id }),
                  let marker = reference.items.first(where: { $0.id == "MenuBox.marker" }),
                  let neighbor = reference.items.filter({ !$0.isTransientSystemIndicator &&
                      $0.frame.minX >= marker.frame.maxX && $0.id != "MenuBox.marker" })
                    .min(by: { $0.frame.minX < $1.frame.minX }),
                  let anchor = current.items.first(where: { $0.id == neighbor.id }) else { throw Failure.boundary }
            let known = Set(old.items.map(\.id))
            for item in current.items where !known.contains(item.id) && !item.isTransientSystemIndicator {
                guard current.frame.contains(item.frame), item.frame.width > 0, item.frame.height > 0,
                      item.bundle != NativeMenuBarPreferences.ownBundle else { throw Failure.incomplete }
                if item.frame.maxX <= anchor.frame.minX {
                    if usesSystemControl(item) { leftSystems.insert(item.id) }
                    else { leftApps.insert(item.bundle) }
                } else if item.frame.minX >= anchor.frame.maxX {
                    if usesSystemControl(item) { rightSystems.insert(item.id) }
                    else { rightApps.insert(item.bundle) }
                } else { throw Failure.boundary }
            }
            // Existing protected apps still belong to the visible side, even
            // if another item of the same app has just appeared on the left.
            rightApps.formUnion(current.items.filter {
                known.contains($0.id) && $0.bundle != NativeMenuBarPreferences.ownBundle &&
                    !usesSystemControl($0)
            }.map(\.bundle))
            rightSystems.formUnion(current.items.filter {
                known.contains($0.id) && usesSystemControl($0) && !$0.isTransientSystemIndicator
            }.map(\.id))
            let historical = old.items.filter {
                plan.applicationKeys.contains($0.bundle) || plan.systemItemIDs.contains($0.id) || $0.id == "MenuBox.marker"
            }
            updatedBars.append(Bar(frame: current.frame, items: historical + current.items))
        }
        guard leftApps.isDisjoint(with: rightApps), leftSystems.isDisjoint(with: rightSystems) else { throw Failure.boundary }
        let applications = plan.applicationKeys.union(leftApps)
        let systems = plan.systemItemIDs.union(leftSystems)
        let updated = NativeMenuBarSnapshot(bars: updatedBars,
            executables: before.executables.merging(executables, uniquingKeysWith: { _, new in new }),
            applicationControlBundles: before.applicationControlBundles.union(applicationControlBundles))
        let protected = Dictionary(uniqueKeysWithValues: updatedBars.map { bar in
            (bar.id, Set(bar.items.filter { !applications.contains($0.bundle) &&
                !systems.contains($0.id) && !$0.isTransientSystemIndicator }.map(\.id)))
        })
        // New right-side items also need valid, non-overlapping protected order.
        let protectedSnapshot = NativeMenuBarSnapshot(bars: bars.map { bar in
            Bar(frame: bar.frame, items: bar.items.filter { !applications.contains($0.bundle) && !systems.contains($0.id) })
        }, executables: executables)
        try protectedSnapshot.verifyHidden(applications, comparedTo: updated, markerHidden: true, systemItems: systems)
        return HiddenSectionUpdate(baseline: updated, plan: .init(applicationKeys: applications,
            protectedItemsByDisplay: protected, systemItemIDs: systems))
    }

    func hiddenState(_ applications: Set<String>, comparedTo before: NativeMenuBarSnapshot,
                     systemItems: Set<String>) throws -> HiddenState {
        guard Set(bars.map(\.id)) == Set(before.bars.map(\.id)) else { return .layoutChanged }
        func protected(_ item: Item) -> Bool {
            !applications.contains(item.bundle) && !systemItems.contains(item.id) &&
                item.id != "MenuBox.marker" &&
                !item.isTransientSystemIndicator
        }
        for old in before.bars {
            guard let current = bars.first(where: { $0.id == old.id }),
                  Set(current.items.filter(protected).map(\.id)) == Set(old.items.filter(protected).map(\.id))
            else { return .layoutChanged }
        }
        // Validate protected controls even when a selected item has reappeared.
        let filtered = bars.map { Bar(frame: $0.frame, items: $0.items.filter(protected)) }
        do {
            try NativeMenuBarSnapshot(bars: filtered, executables: executables)
                .verifyHidden(applications, comparedTo: before, markerHidden: true, systemItems: systemItems)
        } catch { throw Failure.incomplete }
        return bars.flatMap(\.items).contains {
            applications.contains($0.bundle) || systemItems.contains($0.id) || $0.id == "MenuBox.marker"
        } ? .targetsVisible : .hidden
    }

    private static func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(item, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func children(_ item: AXUIElement, _ name: String = kAXChildrenAttribute as String) -> [AXUIElement] {
        attribute(item, name) as? [AXUIElement] ?? []
    }
    private static func rect(_ item: AXUIElement) -> CGRect? {
        guard let p = attribute(item, kAXPositionAttribute as String), let s = attribute(item, kAXSizeAttribute as String),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func identifier(_ item: AXUIElement, agentPID: pid_t, depth: Int = 0) -> String {
        if let id = attribute(item, kAXIdentifierAttribute as String) as? String, !id.isEmpty { return id }
        var pid: pid_t = 0
        guard depth < 5, AXUIElementGetPid(item, &pid) == .success, pid == agentPID else { return "" }
        return children(item).lazy.map { identifier($0, agentPID: agentPID, depth: depth + 1) }.first { !$0.isEmpty } ?? ""
    }
}
