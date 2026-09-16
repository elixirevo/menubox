import AppKit
import ApplicationServices
import CoreGraphics

final class MenuBarProxyTarget: @unchecked Sendable {
    let appKitFrame: NSRect
    let appKitClickPoint: NSPoint
    let accessibilityElement: AXUIElement
    let role: String
    let title: String
    let description: String
    let actions: [String]
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let appName: String
    let icon: NSImage?

    init(
        appKitFrame: NSRect,
        appKitClickPoint: NSPoint,
        accessibilityElement: AXUIElement,
        role: String,
        title: String,
        description: String,
        actions: [String],
        processIdentifier: pid_t,
        bundleIdentifier: String,
        appName: String,
        icon: NSImage?
    ) {
        self.appKitFrame = appKitFrame
        self.appKitClickPoint = appKitClickPoint
        self.accessibilityElement = accessibilityElement
        self.role = role
        self.title = title
        self.description = description
        self.actions = actions
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.icon = icon
    }

    var displayName: String {
        if !description.isEmpty {
            return description
        }
        if !title.isEmpty {
            return title
        }
        if !appName.isEmpty {
            return appName
        }
        return role
    }
}

struct MenuBarProxyClick {
    let appKitPoint: NSPoint
    let searchRect: NSRect
    let target: MenuBarProxyTarget?
    let revealBeforeForwarding: Bool
    let menuAnchorPoint: NSPoint?

    init(
        appKitPoint: NSPoint,
        searchRect: NSRect,
        target: MenuBarProxyTarget?,
        revealBeforeForwarding: Bool = true,
        menuAnchorPoint: NSPoint? = nil
    ) {
        self.appKitPoint = appKitPoint
        self.searchRect = searchRect
        self.target = target
        self.revealBeforeForwarding = revealBeforeForwarding
        self.menuAnchorPoint = menuAnchorPoint
    }
}

final class MenuBarProxyMenuItem: @unchecked Sendable {
    let title: String
    let identity: String
    let role: String
    let actions: [String]
    let accessibilityElement: AXUIElement?
    let appKitFrame: NSRect?
    let isSeparator: Bool
    let isEnabled: Bool
    let isChecked: Bool
    let children: [MenuBarProxyMenuItem]

    init(
        title: String,
        identity: String,
        role: String,
        actions: [String],
        accessibilityElement: AXUIElement?,
        appKitFrame: NSRect?,
        isSeparator: Bool,
        isEnabled: Bool,
        isChecked: Bool,
        children: [MenuBarProxyMenuItem]
    ) {
        self.title = title
        self.identity = identity
        self.role = role
        self.actions = actions
        self.accessibilityElement = accessibilityElement
        self.appKitFrame = appKitFrame
        self.isSeparator = isSeparator
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
    }
}

struct MenuBarProxyMenuSelection: @unchecked Sendable {
    let item: MenuBarProxyMenuItem
    let path: [String]
    let identityPath: [String]
}

struct OpenedStatusItemMenu {
    let items: [MenuBarProxyMenuItem]
    let roots: [AXUIElement]

    func cancel() {
        for root in roots {
            AXUIElementSetMessagingTimeout(root, 0.2)
            _ = AXUIElementPerformAction(root, kAXCancelAction as CFString)
        }
    }
}

enum MenuBarProxyScanner {
    struct RunningApplicationInfo: @unchecked Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let localizedName: String
        let icon: NSImage?
    }

    private struct MenuWindowProbe {
        let bounds: CGRect
        let layer: Int
        let ownerMatchesTarget: Bool
        let distance: CGFloat
    }

    private static let statusItemScanMessagingTimeout: Float = 0.15

    static func runningApplicationInfo(excludingProcessIdentifier excludedPID: pid_t) -> [RunningApplicationInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier > 0, app.processIdentifier != excludedPID else {
                return nil
            }
            return RunningApplicationInfo(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier ?? "",
                localizedName: app.localizedName ?? "",
                icon: app.icon
            )
        }
    }

    static func targets(in appKitRect: NSRect) -> [MenuBarProxyTarget] {
        guard ClickForwarder.accessibilityTrusted, appKitRect.width > 0, appKitRect.height > 0 else {
            return []
        }

        let systemWide = AXUIElementCreateSystemWide()
        let sampleYs = ySamples(in: appKitRect)
        var targetsByKey: [String: MenuBarProxyTarget] = [:]

        for appKitY in sampleYs {
            var x = appKitRect.minX + 2
            while x <= appKitRect.maxX - 2 {
                let quartzPoint = MenuBarGeometry.quartzPoint(fromAppKitPoint: NSPoint(x: x, y: appKitY))
                var element: AXUIElement?
                let error = AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(quartzPoint.x),
                    Float(quartzPoint.y),
                    &element
                )
                if error == .success, let element {
                    for candidate in elementChain(startingAt: element) {
                        if let target = target(from: candidate, in: appKitRect) {
                            targetsByKey[key(for: target)] = target
                            break
                        }
                    }
                }
                x += 3
            }
        }

        return Array(targetsByKey.values).sorted { $0.appKitFrame.minX < $1.appKitFrame.minX }
    }

    static func targetsBeforeMarker(tapeFrame: NSRect, excludingProcessIdentifier excludedPID: pid_t) -> [MenuBarProxyTarget] {
        targetsBeforeMarker(
            tapeFrame: tapeFrame,
            runningApplications: runningApplicationInfo(excludingProcessIdentifier: excludedPID)
        )
    }

    static func statusItemTargets(
        runningApplications: [RunningApplicationInfo]
    ) -> [MenuBarProxyTarget] {
        scanStatusItemTargets(
            runningApplications: runningApplications,
            markerX: nil
        )
    }

    static func targetsBeforeMarker(
        tapeFrame: NSRect,
        runningApplications: [RunningApplicationInfo]
    ) -> [MenuBarProxyTarget] {
        scanStatusItemTargets(
            runningApplications: runningApplications,
            markerX: tapeFrame.minX
        )
    }

    private static func scanStatusItemTargets(
        runningApplications: [RunningApplicationInfo],
        markerX: CGFloat?
    ) -> [MenuBarProxyTarget] {
        guard ClickForwarder.accessibilityTrusted else {
            return []
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        var targetsByKey: [String: MenuBarProxyTarget] = [:]
        let applicationInfoByPID = Dictionary(uniqueKeysWithValues: runningApplications.map {
            ($0.processIdentifier, $0)
        })

        for app in runningApplications {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            applyStatusItemScanTimeout(to: appElement)
            let bars = accessibilityElements(attribute: "AXExtrasMenuBar", from: appElement)
            for bar in bars {
                applyStatusItemScanTimeout(to: bar)
                for item in accessibilityElements(attribute: kAXChildrenAttribute as String, from: bar) {
                    applyStatusItemScanTimeout(to: item)
                    guard let target = target(
                            from: item,
                            clippingRect: nil,
                            applicationInfoByPID: applicationInfoByPID
                          ),
                          markerX.map({ target.appKitFrame.maxX <= $0 + 1 }) ?? true else {
                        continue
                    }
                    targetsByKey[key(for: target)] = target
                }
            }
        }

        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        NSLog(
            "[MenuBox] Status item scan loaded %ld targets from %ld apps marker=%@ in %.1fms",
            targetsByKey.count,
            runningApplications.count,
            markerX.map { String(format: "%.1f", Double($0)) } ?? "all",
            elapsedMilliseconds
        )

        return Array(targetsByKey.values).sorted { $0.appKitFrame.minX < $1.appKitFrame.minX }
    }

    static func bestTarget(near point: NSPoint, in appKitRect: NSRect) -> MenuBarProxyTarget? {
        let candidates = targets(in: appKitRect)
        guard !candidates.isEmpty else { return nil }

        let expandedHits = candidates.filter { $0.appKitFrame.insetBy(dx: -4, dy: -8).contains(point) }
        if let hit = expandedHits.min(by: { distance($0.appKitClickPoint, point) < distance($1.appKitClickPoint, point) }) {
            return hit
        }

        let tolerance = max(12, appKitRect.height * 0.75)
        return candidates
            .filter { abs($0.appKitClickPoint.x - point.x) <= tolerance }
            .min { distance($0.appKitClickPoint, point) < distance($1.appKitClickPoint, point) }
    }

    static func refreshedTarget(from target: MenuBarProxyTarget) -> MenuBarProxyTarget? {
        self.target(from: target.accessibilityElement, clippingRect: nil)
    }

    static func refreshedStatusItemTarget(from original: MenuBarProxyTarget) -> MenuBarProxyTarget? {
        guard let app = NSRunningApplication(processIdentifier: original.processIdentifier),
              app.bundleIdentifier == original.bundleIdentifier, !app.isTerminated else { return nil }
        if let current = refreshedTarget(from: original) { return current }
        let candidates = statusItemTargets(runningApplications: [.init(
            processIdentifier: original.processIdentifier, bundleIdentifier: original.bundleIdentifier,
            localizedName: original.appName, icon: original.icon)])
        let matches = candidates.filter {
            $0.role == original.role && $0.title == original.title && $0.description == original.description
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func requestExplicitStatusItemMenu(for target: MenuBarProxyTarget) -> Bool {
        var actions: CFArray?
        AXUIElementSetMessagingTimeout(target.accessibilityElement, 0.2)
        guard AXUIElementCopyActionNames(target.accessibilityElement, &actions) == .success,
              (actions as? [String] ?? []).contains(kAXShowMenuAction) else { return false }
        return AXUIElementPerformAction(target.accessibilityElement, kAXShowMenuAction as CFString) == .success
    }

    static func matchingTarget(for original: MenuBarProxyTarget, in appKitRect: NSRect) -> MenuBarProxyTarget? {
        let candidates = targets(in: appKitRect)
        guard !candidates.isEmpty else { return nil }

        let scored = candidates
            .map { candidate in (target: candidate, score: matchScore(candidate: candidate, original: original)) }
            .filter { $0.score >= 8 }

        return scored.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return distance(lhs.target.appKitClickPoint, original.appKitClickPoint) >
                distance(rhs.target.appKitClickPoint, original.appKitClickPoint)
        }?.target
    }

    static func proxyMenuItems(for target: MenuBarProxyTarget) -> [MenuBarProxyMenuItem] {
        proxyMenuItems(for: target, screenProbeRoots: screenProbeMenuRoots(for: target))
    }

    static func immediateProxyMenuItems(for target: MenuBarProxyTarget) -> [MenuBarProxyMenuItem] {
        guard let items = bestProxyMenuItems(from: directMenuRoots(for: target)) else {
            return []
        }
        NSLog("[MenuBox] Immediate proxy menu items=%ld target=%@", visibleItemCount(items), target.displayName)
        return items
    }

    /// Only menus opened by the status item, never the application's main menu bar.
    static func openedStatusItemMenu(for target: MenuBarProxyTarget) -> OpenedStatusItemMenu? {
        var roots = directMenuRoots(for: target)
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        for attribute in [kAXChildrenAttribute as String, kAXFocusedUIElementAttribute as String] {
            for element in accessibilityElements(attribute: attribute, from: app) {
                roots.append(contentsOf: elementChain(startingAt: element)
                    .filter { stringAttribute(kAXRoleAttribute, from: $0) == "AXMenu" })
            }
        }
        roots = uniqueElements(roots).filter { appKitFrame(for: $0) != nil }
        guard let items = bestProxyMenuItems(from: roots) else { return nil }
        return OpenedStatusItemMenu(items: items, roots: roots)
    }

    static func currentMenuItem(
        matching selection: MenuBarProxyMenuSelection,
        in items: [MenuBarProxyMenuItem]
    ) -> MenuBarProxyMenuItem? {
        func uniqueItem(_ path: ArraySlice<String>, in items: [MenuBarProxyMenuItem]) -> MenuBarProxyMenuItem? {
            guard let title = path.first else { return nil }
            let matches = items.filter { !$0.isSeparator && normalizedMenuTitle($0.title) == normalizedMenuTitle(title) }
            guard matches.count == 1, let item = matches.first, item.isEnabled else { return nil }
            return path.count == 1 ? item : uniqueItem(path.dropFirst(), in: item.children)
        }
        guard let item = uniqueItem(selection.path[...], in: items),
              item.role == selection.item.role else { return nil }
        return item
    }

    private static func proxyMenuItems(
        for target: MenuBarProxyTarget,
        screenProbeRoots: [AXUIElement]
    ) -> [MenuBarProxyMenuItem] {
        if let visibleItems = bestProxyMenuItems(from: axMenuRoots(in: screenProbeRoots)) {
            return visibleItems
        }

        if let directItems = bestProxyMenuItems(from: directMenuRoots(for: target)) {
            return directItems
        }

        return []
    }

    private static func bestProxyMenuItems(from roots: [AXUIElement]) -> [MenuBarProxyMenuItem]? {
        var bestItems: [MenuBarProxyMenuItem] = []
        for root in roots {
            let items = proxyMenuItems(from: root, depth: 0)
            if items.contains(where: { !$0.isSeparator }) {
                let trimmed = trimSeparators(items)
                if visibleItemCount(trimmed) > visibleItemCount(bestItems) {
                    bestItems = trimmed
                }
                if stringAttribute(kAXRoleAttribute, from: root) == "AXMenu" || visibleItemCount(trimmed) > 1 {
                    return trimmed
                }
            }
        }

        return bestItems.contains(where: { !$0.isSeparator }) ? bestItems : nil
    }

    private static func directMenuRoots(for target: MenuBarProxyTarget) -> [AXUIElement] {
        var roots: [AXUIElement] = []

        for attribute in ["AXShownMenu", "AXMenu"] {
            for root in accessibilityElements(attribute: attribute, from: target.accessibilityElement)
            where stringAttribute(kAXRoleAttribute, from: root) == "AXMenu" &&
                !roots.contains(where: { CFEqual($0, root) }) {
                roots.append(root)
            }
        }

        for child in accessibilityElements(attribute: kAXChildrenAttribute as String, from: target.accessibilityElement)
        where stringAttribute(kAXRoleAttribute, from: child) == "AXMenu" &&
            !roots.contains(where: { CFEqual($0, child) }) {
            roots.append(child)
        }

        return roots
    }

    private static func axMenuRoots(in roots: [AXUIElement]) -> [AXUIElement] {
        roots.filter { stringAttribute(kAXRoleAttribute, from: $0) == "AXMenu" }
    }

    static func availableProxyMenuItems(for target: MenuBarProxyTarget) -> [MenuBarProxyMenuItem] {
        let screenProbeRoots = screenProbeMenuRoots(for: target)
        let strictItems = proxyMenuItems(for: target, screenProbeRoots: screenProbeRoots)
        if strictItems.contains(where: { !$0.isSeparator }) {
            NSLog("[MenuBox] Proxy menu strict items=%ld target=%@", visibleItemCount(strictItems), target.displayName)
            return strictItems
        }
        NSLog("[MenuBox] Proxy menu unsupported: no AXMenu target=%@", target.displayName)
        return []
    }

    static func proxyMenuItem(matching selection: MenuBarProxyMenuSelection, for target: MenuBarProxyTarget) -> MenuBarProxyMenuItem? {
        let items = availableProxyMenuItems(for: target)
        if let item = proxyMenuItem(matchingIdentityPath: selection.identityPath, in: items) {
            return item
        }

        if let item = proxyMenuItem(matchingTitlePath: selection.path, in: items) {
            return item
        }

        let fallbackTitle = normalizedMenuTitle(selection.item.title)
        return flattenedMenuItems(items).first { candidate in
            !candidate.isSeparator &&
                candidate.role == selection.item.role &&
                normalizedMenuTitle(candidate.title) == fallbackTitle
        }
    }

    private static func target(from element: AXUIElement, in appKitRect: NSRect) -> MenuBarProxyTarget? {
        target(from: element, clippingRect: appKitRect)
    }

    private static func target(
        from element: AXUIElement,
        clippingRect appKitRect: NSRect?,
        applicationInfoByPID: [pid_t: RunningApplicationInfo]? = nil
    ) -> MenuBarProxyTarget? {
        guard let frame = appKitFrame(for: element) else {
            return nil
        }

        if let appKitRect {
            let intersection = frame.intersection(appKitRect)
            guard !intersection.isNull,
                  intersection.width >= 5,
                  intersection.height >= 8 else {
                return nil
            }
        }

        let maxTargetHeight = appKitRect.map { max(60, $0.height * 2.5) } ?? 60
        guard frame.width >= 8,
              frame.width <= max(180, appKitRect?.width ?? 180),
              frame.height <= maxTargetHeight else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
        let title = stringAttribute(kAXTitleAttribute, from: element) ?? ""
        let description = stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
        let actions = actionNames(from: element)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let applicationInfo = applicationInfoByPID?[pid]
        let app = applicationInfo == nil ? NSRunningApplication(processIdentifier: pid) : nil
        let bundleIdentifier = applicationInfo?.bundleIdentifier ?? app?.bundleIdentifier ?? ""
        let appName = applicationInfo?.localizedName ?? app?.localizedName ?? ""
        let isMenuBarItem = role == "AXMenuBarItem"
        let isActionableMenuBarItem = isMenuBarItem &&
            (actions.isEmpty || actions.contains(kAXPressAction) || actions.contains(kAXShowMenuAction))
        let isActionableMenuBarControl = isMenuBarControlRole(role) &&
            (actions.contains(kAXPressAction) || actions.contains(kAXShowMenuAction))
        let hasExplicitMenuAction = actions.contains(kAXShowMenuAction)
        guard isActionableMenuBarItem || isActionableMenuBarControl || hasExplicitMenuAction else {
            return nil
        }

        let clickX: CGFloat
        let clickY: CGFloat
        if let appKitRect {
            clickX = max(appKitRect.minX + 1, min(appKitRect.maxX - 1, frame.midX))
            clickY = appKitRect.midY
        } else {
            clickX = frame.midX
            clickY = frame.midY
        }

        return MenuBarProxyTarget(
            appKitFrame: frame,
            appKitClickPoint: NSPoint(x: clickX, y: clickY),
            accessibilityElement: element,
            role: role,
            title: title,
            description: description,
            actions: actions,
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            icon: applicationInfo?.icon ?? app?.icon
        )
    }

    private static func appKitFrame(for element: AXUIElement) -> NSRect? {
        guard let quartzPosition = cgPointAttribute(kAXPositionAttribute, from: element),
              let size = cgSizeAttribute(kAXSizeAttribute, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        let appKitTopLeft = MenuBarGeometry.appKitPoint(fromQuartzPoint: quartzPosition)
        return NSRect(
            x: appKitTopLeft.x,
            y: appKitTopLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private static func cgPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func cgSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }
        return String(describing: value)
    }

    private static func actionNames(from element: AXUIElement) -> [String] {
        var value: CFArray?
        let error = AXUIElementCopyActionNames(element, &value)
        guard error == .success, let value else {
            return []
        }
        return value as? [String] ?? []
    }

    private static func elementChain(startingAt element: AXUIElement) -> [AXUIElement] {
        var elements = [element]
        var current = element

        for _ in 0..<8 {
            var parentValue: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue)
            guard error == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }

            let parent = parentValue as! AXUIElement
            elements.append(parent)
            current = parent
        }

        return elements
    }

    private static func accessibilityElements(attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            return []
        }

        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }

        if let elements = value as? [AXUIElement] {
            return elements
        }

        if let values = value as? [Any] {
            return values.compactMap { candidate in
                guard CFGetTypeID(candidate as CFTypeRef) == AXUIElementGetTypeID() else {
                    return nil
                }
                return (candidate as! AXUIElement)
            }
        }

        return []
    }

    private static func applyStatusItemScanTimeout(to element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, statusItemScanMessagingTimeout)
    }

    private static func applicationElements(matching target: MenuBarProxyTarget) -> [AXUIElement] {
        var elements: [AXUIElement] = [AXUIElementCreateApplication(target.processIdentifier)]
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier > 0 &&
            app.processIdentifier != target.processIdentifier &&
            runningApplicationMatchesTarget(processIdentifier: app.processIdentifier, target: target) {
            elements.append(AXUIElementCreateApplication(app.processIdentifier))
        }
        return uniqueElements(elements)
    }

    private static func statusItemRoots(matching target: MenuBarProxyTarget) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        for appElement in applicationElements(matching: target) {
            for bar in accessibilityElements(attribute: "AXExtrasMenuBar", from: appElement) {
                for item in accessibilityElements(attribute: kAXChildrenAttribute as String, from: bar)
                where statusItem(item, matches: target) {
                    roots.append(item)
                    roots.append(contentsOf: relatedAccessibilityElements(from: item))
                }
            }
        }
        return uniqueElements(roots)
    }

    private static func statusItem(_ element: AXUIElement, matches target: MenuBarProxyTarget) -> Bool {
        if CFEqual(element, target.accessibilityElement) {
            return true
        }

        guard elementBelongsToTarget(element, target: target),
              let frame = appKitFrame(for: element) else {
            return false
        }

        if frame.insetBy(dx: -12, dy: -8).intersects(target.appKitFrame) {
            return true
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        guard role == target.role || isMenuBarControlRole(role) || role == "AXMenuBarItem" else {
            return false
        }

        let title = stringAttribute(kAXTitleAttribute, from: element) ?? ""
        let description = stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
        let label = menuLabel(title: title, description: description)
        let targetLabel = menuLabel(title: target.title, description: target.description)
        return !label.isEmpty && label == targetLabel
    }

    private static func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var unique: [AXUIElement] = []
        for element in elements where !unique.contains(where: { CFEqual($0, element) }) {
            unique.append(element)
        }
        return unique
    }

    private static func screenProbeMenuRoots(for target: MenuBarProxyTarget) -> [AXUIElement] {
        let windows = menuWindowProbes(for: target)
        guard !windows.isEmpty else { return [] }

        let systemWide = AXUIElementCreateSystemWide()
        var roots: [AXUIElement] = []

        for window in windows.prefix(6) {
            var foundStrongRootInWindow = false
            for point in menuProbePoints(in: window.bounds) {
                var element: AXUIElement?
                let error = AXUIElementCopyElementAtPosition(
                    systemWide,
                    Float(point.x),
                    Float(point.y),
                    &element
                )
                guard error == .success, let element else {
                    continue
                }

                for root in menuRootCandidates(
                    startingAt: element,
                    target: target,
                    allowForeignPopupRoots: true
                )
                where !roots.contains(where: { CFEqual($0, root) }) {
                    roots.append(root)
                    if isProbeRootLikelyMenuSurface(root) {
                        foundStrongRootInWindow = true
                    }
                }

                if foundStrongRootInWindow {
                    break
                }
            }

            if foundStrongRootInWindow {
                break
            }
        }

        if !roots.isEmpty {
            NSLog("[MenuBox] Screen-probed %ld AX menu roots from %ld windows target=%@", roots.count, windows.count, target.displayName)
        } else {
            NSLog("[MenuBox] Screen probe found %ld menu-like windows but no AX roots target=%@", windows.count, target.displayName)
        }
        return roots
    }

    private static func isProbeRootLikelyMenuSurface(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        return role == "AXMenu"
    }

    private static func menuWindowProbes(for target: MenuBarProxyTarget) -> [MenuWindowProbe] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let targetPoint = MenuBarGeometry.quartzPoint(fromAppKitPoint: target.appKitClickPoint)
        let targetPID = Int(target.processIdentifier)
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return windowInfo.compactMap { info -> MenuWindowProbe? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  ownerPID != currentPID,
                  let boundsValue = info[kCGWindowBounds as String],
                  CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID(),
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  bounds.width >= 12,
                  bounds.height >= 10,
                  bounds.width <= 900,
                  bounds.height <= 1200 else {
                return nil
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else { return nil }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let horizontalSlack = max(CGFloat(220), bounds.width)
            let horizontallyNear = targetPoint.x >= bounds.minX - horizontalSlack &&
                targetPoint.x <= bounds.maxX + horizontalSlack
            let verticallyNearMenuBar = bounds.minY <= targetPoint.y + 420 &&
                bounds.maxY >= targetPoint.y - 48
            let likelyPopup = bounds.width <= 620 &&
                bounds.height <= 1000 &&
                horizontallyNear &&
                verticallyNearMenuBar

            let popupMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
            let isLikelyMenuLayer = layer >= max(1, popupMenuLevel - 10)
            let ownerMatchesTarget = ownerPID == targetPID ||
                runningApplicationMatchesTarget(processIdentifier: pid_t(ownerPID), target: target)
            guard ownerMatchesTarget || (likelyPopup && isLikelyMenuLayer) else {
                return nil
            }

            let distance = distance(
                NSPoint(x: bounds.midX, y: bounds.minY),
                NSPoint(x: targetPoint.x, y: targetPoint.y)
            )
            return MenuWindowProbe(
                bounds: bounds,
                layer: layer,
                ownerMatchesTarget: ownerMatchesTarget,
                distance: distance
            )
        }
        .sorted {
            if $0.ownerMatchesTarget != $1.ownerMatchesTarget {
                return $0.ownerMatchesTarget
            }
            if $0.layer != $1.layer {
                return $0.layer > $1.layer
            }
            return $0.distance < $1.distance
        }
    }

    private static func menuProbePoints(in bounds: CGRect) -> [CGPoint] {
        let insetX = min(CGFloat(28), max(CGFloat(8), bounds.width * 0.18))
        let insetY = min(CGFloat(28), max(CGFloat(6), bounds.height * 0.18))
        var rawPoints = [
            CGPoint(x: bounds.midX, y: bounds.minY + insetY),
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.maxY - insetY),
            CGPoint(x: bounds.minX + insetX, y: bounds.midY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.midY),
            CGPoint(x: bounds.minX + insetX, y: bounds.minY + insetY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.minY + insetY)
        ]

        let sampleXs = [
            bounds.minX + insetX,
            bounds.midX,
            bounds.maxX - insetX
        ]
        let sampleYs = [
            bounds.minY + insetY,
            bounds.minY + bounds.height * 0.35,
            bounds.minY + bounds.height * 0.65,
            bounds.maxY - insetY
        ]
        for x in sampleXs {
            for y in sampleYs {
                rawPoints.append(CGPoint(x: x, y: y))
            }
        }

        var points: [CGPoint] = []
        for point in rawPoints {
            let clamped = CGPoint(
                x: max(bounds.minX + 1, min(bounds.maxX - 1, point.x)),
                y: max(bounds.minY + 1, min(bounds.maxY - 1, point.y))
            )
            if !points.contains(where: { abs($0.x - clamped.x) < 1 && abs($0.y - clamped.y) < 1 }) {
                points.append(clamped)
            }
        }
        return points
    }

    private static func menuRootCandidates(
        startingAt element: AXUIElement,
        target: MenuBarProxyTarget,
        allowForeignPopupRoots: Bool
    ) -> [AXUIElement] {
        let chain = elementChain(startingAt: element)
        let targetChain = chain.filter { elementBelongsToTarget($0, target: target) }
        let menuRoots = targetChain.filter { stringAttribute(kAXRoleAttribute, from: $0) == "AXMenu" }
        if !menuRoots.isEmpty {
            return menuRoots
        }

        if allowForeignPopupRoots {
            let foreignMenuRoots = chain.filter { stringAttribute(kAXRoleAttribute, from: $0) == "AXMenu" }
            if !foreignMenuRoots.isEmpty {
                return foreignMenuRoots
            }
        }

        return []
    }

    private static func proxyMenuItems(from element: AXUIElement, depth: Int) -> [MenuBarProxyMenuItem] {
        guard depth <= 8 else { return [] }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let children = relatedAccessibilityElements(from: element)

        if role == "AXMenu" {
            return trimSeparators(children.compactMap { proxyMenuItem(from: $0, depth: depth + 1) })
        }

        if role == "AXMenuItem" || role == "AXSeparator" {
            return proxyMenuItem(from: element, depth: depth).map { [$0] } ?? []
        }

        var result: [MenuBarProxyMenuItem] = []
        for child in children {
            result.append(contentsOf: proxyMenuItems(from: child, depth: depth + 1))
            if result.count >= 80 {
                break
            }
        }
        return trimSeparators(result)
    }

    private static func proxyMenuItem(from element: AXUIElement, depth: Int) -> MenuBarProxyMenuItem? {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let title = stringAttribute(kAXTitleAttribute, from: element) ?? ""
        let description = stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
        let children = relatedAccessibilityElements(from: element)
            .flatMap { proxyMenuItems(from: $0, depth: depth + 1) }
        let directLabel = menuLabel(title: title, description: description)
        let rawLabel = directLabel.isEmpty ? descendantTextLabel(from: element) : directLabel
        let label = rawLabel.isEmpty && !children.isEmpty ? fallbackLabel(for: role) : rawLabel
        let actions = actionNames(from: element)
        let isSeparator = role == "AXSeparator" || (role == "AXMenuItem" && label.isEmpty && children.isEmpty)

        return MenuBarProxyMenuItem(
            title: label,
            identity: proxyElementIdentity(role: role, title: label, element: element),
            role: role,
            actions: actions,
            accessibilityElement: isSeparator ? nil : element,
            appKitFrame: isSeparator ? nil : appKitFrame(for: element),
            isSeparator: isSeparator,
            isEnabled: boolAttribute(kAXEnabledAttribute, from: element) ?? true,
            isChecked: isCheckedMenuItem(element),
            children: trimSeparators(children)
        )
    }

    private static func proxyElementIdentity(role: String, title: String, element: AXUIElement?) -> String {
        let frame = element.flatMap { appKitFrame(for: $0) }
        let actions = element.map { actionNames(from: $0).joined(separator: ",") } ?? ""
        return [
            role,
            normalizedMenuTitle(title),
            frame.map { String(Int($0.minX.rounded())) } ?? "",
            frame.map { String(Int($0.minY.rounded())) } ?? "",
            frame.map { String(Int($0.width.rounded())) } ?? "",
            frame.map { String(Int($0.height.rounded())) } ?? "",
            actions
        ].joined(separator: ":")
    }

    private static func isMenuBarControlRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton":
            return true
        default:
            return false
        }
    }

    private static func proxyMenuItem(matchingIdentityPath path: [String], in items: [MenuBarProxyMenuItem]) -> MenuBarProxyMenuItem? {
        guard let head = path.first else { return nil }

        for item in items where !item.isSeparator && item.identity == head {
            if path.count == 1 {
                return item
            }
            if let child = proxyMenuItem(matchingIdentityPath: Array(path.dropFirst()), in: item.children) {
                return child
            }
        }

        return nil
    }

    private static func proxyMenuItem(matchingTitlePath path: [String], in items: [MenuBarProxyMenuItem]) -> MenuBarProxyMenuItem? {
        guard let head = path.first else { return nil }
        let normalizedHead = normalizedMenuTitle(head)

        for item in items where !item.isSeparator && normalizedMenuTitle(item.title) == normalizedHead {
            if path.count == 1 {
                return item
            }
            if let child = proxyMenuItem(matchingTitlePath: Array(path.dropFirst()), in: item.children) {
                return child
            }
        }

        return nil
    }

    private static func flattenedMenuItems(_ items: [MenuBarProxyMenuItem]) -> [MenuBarProxyMenuItem] {
        var result: [MenuBarProxyMenuItem] = []
        for item in items {
            result.append(item)
            result.append(contentsOf: flattenedMenuItems(item.children))
        }
        return result
    }

    private static func fallbackLabel(for role: String) -> String {
        switch role {
        case "AXMenuItem":
            return "Menu item"
        case "AXButton":
            return "Button"
        case "AXCheckBox":
            return "Checkbox"
        case "AXRadioButton":
            return "Radio button"
        case "AXPopUpButton":
            return "Pop-up button"
        case "AXGroup", "AXRow", "AXCell":
            return "Item"
        default:
            return ""
        }
    }

    private static func relatedAccessibilityElements(from element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            "AXMenu",
            "AXShownMenu",
            kAXChildrenAttribute as String,
            "AXVisibleChildren",
            "AXRows",
            "AXColumns",
            "AXContents",
            "AXLinkedUIElements",
            "AXDisclosedRows"
        ]

        var result: [AXUIElement] = []
        for attribute in attributes {
            for child in accessibilityElements(attribute: attribute, from: element)
            where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    private static func elementBelongsToTarget(_ element: AXUIElement, target: MenuBarProxyTarget) -> Bool {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)
        guard error == .success else { return false }
        if pid == target.processIdentifier {
            return true
        }
        return runningApplicationMatchesTarget(processIdentifier: pid, target: target)
    }

    private static func runningApplicationMatchesTarget(
        processIdentifier: pid_t,
        target: MenuBarProxyTarget
    ) -> Bool {
        guard processIdentifier > 0,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }

        if !target.bundleIdentifier.isEmpty, app.bundleIdentifier == target.bundleIdentifier {
            return true
        }
        if !target.appName.isEmpty, app.localizedName == target.appName {
            return true
        }
        return false
    }

    private static func menuLabel(title: String, description: String) -> String {
        let title = normalizedDisplayLabel(title)
        if !title.isEmpty {
            return title
        }
        return normalizedDisplayLabel(description)
    }

    private static func descendantTextLabel(from element: AXUIElement) -> String {
        var labels: [String] = []
        var visited = Set<CFHashCode>()
        collectDescendantTextLabels(from: element, depth: 0, labels: &labels, visited: &visited)
        return labels.prefix(4).joined(separator: " ")
    }

    private static func collectDescendantTextLabels(
        from element: AXUIElement,
        depth: Int,
        labels: inout [String],
        visited: inout Set<CFHashCode>
    ) {
        guard depth <= 4,
              labels.count < 4,
              visited.insert(CFHash(element)).inserted else {
            return
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        if depth > 0 || isTextLikeRole(role) {
            let title = stringAttribute(kAXTitleAttribute, from: element) ?? ""
            let description = stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
            appendLabelFragment(menuLabel(title: title, description: description), to: &labels)

            if isTextLikeRole(role) {
                let value = stringAttribute(kAXValueAttribute, from: element) ?? ""
                appendLabelFragment(value, to: &labels)
            }

            let help = stringAttribute(kAXHelpAttribute as String, from: element) ?? ""
            appendLabelFragment(help, to: &labels)

            let placeholder = stringAttribute("AXPlaceholderValue", from: element) ?? ""
            appendLabelFragment(placeholder, to: &labels)
        }

        for child in relatedAccessibilityElements(from: element) {
            collectDescendantTextLabels(from: child, depth: depth + 1, labels: &labels, visited: &visited)
            if labels.count >= 4 {
                break
            }
        }
    }

    private static func appendLabelFragment(_ fragment: String, to labels: inout [String]) {
        let normalized = normalizedDisplayLabel(fragment)
        guard !normalized.isEmpty,
              normalized.count <= 80,
              !labels.contains(normalized) else {
            return
        }
        labels.append(normalized)
    }

    private static func isTextLikeRole(_ role: String) -> Bool {
        switch role {
        case "AXStaticText", "AXTextField", "AXMenuItem", "AXButton", "AXCheckBox", "AXRadioButton":
            return true
        default:
            return false
        }
    }

    private static func normalizedDisplayLabel(_ label: String) -> String {
        label
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedMenuTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimSeparators(_ items: [MenuBarProxyMenuItem]) -> [MenuBarProxyMenuItem] {
        var result = items
        while result.first?.isSeparator == true {
            result.removeFirst()
        }
        while result.last?.isSeparator == true {
            result.removeLast()
        }
        return result
    }

    private static func visibleItemCount(_ items: [MenuBarProxyMenuItem]) -> Int {
        items.reduce(0) { partial, item in
            partial + (item.isSeparator ? 0 : 1)
        }
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }
        return value as? Bool
    }

    private static func isCheckedMenuItem(_ element: AXUIElement) -> Bool {
        if let value = intAttribute(kAXValueAttribute, from: element) {
            return value != 0
        }
        if let mark = stringAttribute("AXMenuItemMarkChar", from: element) {
            return !mark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func ySamples(in rect: NSRect) -> [CGFloat] {
        let minY = rect.minY + min(6, rect.height / 4)
        let maxY = rect.maxY - min(6, rect.height / 4)
        let raw = [rect.midY, minY, maxY]
        var samples: [CGFloat] = []

        for y in raw {
            let clamped = max(rect.minY + 1, min(rect.maxY - 1, y))
            if !samples.contains(where: { abs($0 - clamped) < 0.5 }) {
                samples.append(clamped)
            }
        }

        return samples
    }

    private static func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func matchScore(candidate: MenuBarProxyTarget, original: MenuBarProxyTarget) -> Int {
        var score = 0
        if CFEqual(candidate.accessibilityElement, original.accessibilityElement) {
            score += 50
        }
        if candidate.processIdentifier == original.processIdentifier {
            score += 8
        }
        if !candidate.bundleIdentifier.isEmpty, candidate.bundleIdentifier == original.bundleIdentifier {
            score += 4
        }
        if candidate.role == original.role {
            score += 2
        }
        if !candidate.title.isEmpty, candidate.title == original.title {
            score += 3
        }
        if !candidate.description.isEmpty, candidate.description == original.description {
            score += 3
        }
        if !candidate.appName.isEmpty, candidate.appName == original.appName {
            score += 1
        }
        if Set(candidate.actions) == Set(original.actions) {
            score += 1
        }
        return score
    }

    private static func key(for target: MenuBarProxyTarget) -> String {
        let frame = target.appKitFrame
        return [
            String(Int(frame.minX.rounded())),
            String(Int(frame.minY.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded())),
            target.role,
            target.title,
            target.description
        ].joined(separator: ":")
    }
}
