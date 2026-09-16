import AppKit
import ApplicationServices

struct NativeMenuBarSnapshot {
    struct Item {
        var id: String
        let bundle: String
        let frame: CGRect
        let identifier: String
    }
    struct Bar {
        let frame: CGRect
        var items: [Item]
        var id: String { "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)" }
    }
    let bars: [Bar]
    let executables: [String: URL]

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
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            throw Failure.incomplete
        }
        let running = NSWorkspace.shared.runningApplications
        let bundles = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0.bundleIdentifier ?? "") })
        var executables: [String: URL] = [:]
        for app in running {
            if let bundle = app.bundleIdentifier, let url = app.executableURL { executables[bundle] = url }
        }
        var byFrame: [String: Bar] = [:]
        for window in children(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute as String) {
            guard let frame = rect(window) else { continue }
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
        var bars = Array(byFrame.values).sorted { $0.frame.minX < $1.frame.minX }
        guard !bars.isEmpty,
              let known = bars.first(where: { bar in
                  (markerHidden ? ["MenuBox.main"] : ["MenuBox.main", "MenuBox.marker"]).allSatisfy { id in
                      bar.items.filter { $0.bundle == NativeMenuBarPreferences.ownBundle && $0.identifier == id }.count == 1
                  }
              }) else { throw Failure.incomplete }

        for index in bars.indices {
            let own = bars[index].items.indices.filter { bars[index].items[$0].bundle == NativeMenuBarPreferences.ownBundle }
            guard own.count == (markerHidden ? 1 : 2) else { throw Failure.incomplete }
            for itemIndex in own {
                let item = bars[index].items[itemIndex]
                let matches = known.items.filter {
                    $0.bundle == NativeMenuBarPreferences.ownBundle &&
                    abs(($0.frame.minX - known.frame.maxX) - (item.frame.minX - bars[index].frame.maxX)) < 1
                }
                guard matches.count == 1 else { throw Failure.boundary }
                bars[index].items[itemIndex].id = matches[0].identifier
            }
            guard Set(bars[index].items.map(\.id)).count == bars[index].items.count else { throw Failure.incomplete }
        }
        return NativeMenuBarSnapshot(bars: bars, executables: executables)
    }

    func plan() throws -> MenuBarSectionPlanner.Plan {
        guard let first = bars.first else { throw Failure.incomplete }
        let expectedIDs = Set(first.items.map(\.id))
        guard bars.allSatisfy({ Set($0.items.map(\.id)) == expectedIDs }) else { throw Failure.incomplete }
        // Validate each display's boundary directly. A fully expanded external
        // reference display is not required for a laptop-only overflow layout.
        let displays = bars.map { bar -> MenuBarSectionPlanner.Display in
            let items = bar.items.map { item -> MenuBarSectionPlanner.Item in
                let owner: MenuBarSectionPlanner.Owner
                if item.id == "MenuBox.main" { owner = .box }
                else if item.id == "MenuBox.marker" { owner = .marker }
                else if item.bundle.hasPrefix("com.apple.") { owner = .system(item.id) }
                else { owner = .application(item.bundle) }
                return .init(id: item.id, owner: owner, frame: item.frame)
            }
            return .init(id: bar.id, frame: bar.frame, items: items, isResolved: true)
        }
        return try MenuBarSectionPlanner.plan(displays: displays)
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
                    !($0.bundle == "com.apple.MenuBarAgent" && $0.identifier == "plus")
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
            bar.id + ":" + bar.items.filter { $0.identifier != "plus" }.map(\.id).sorted().joined(separator: ",")
        }.sorted().joined(separator: ";")
    }

    func hiddenState(_ applications: Set<String>, comparedTo before: NativeMenuBarSnapshot,
                     systemItems: Set<String>) throws -> HiddenState {
        guard Set(bars.map(\.id)) == Set(before.bars.map(\.id)) else { return .layoutChanged }
        func protected(_ item: Item) -> Bool {
            !applications.contains(item.bundle) && !systemItems.contains(item.id) &&
                item.id != "MenuBox.marker" &&
                !(item.bundle == "com.apple.MenuBarAgent" && item.identifier == "plus")
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
