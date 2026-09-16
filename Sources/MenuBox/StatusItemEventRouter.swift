import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// Routes a secondary click to a status item without changing the spacer.
enum StatusItemEventRouter {
    struct Window {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
        let layer: Int

        init(id: CGWindowID, ownerPID: pid_t, frame: CGRect, layer: Int) {
            self.id = id
            self.ownerPID = ownerPID
            self.frame = frame
            self.layer = layer
        }

        init?(info: [String: Any]) {
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  let layer = info[kCGWindowLayer as String] as? NSNumber else { return nil }
            self.init(id: id.uint32Value, ownerPID: pid.int32Value, frame: frame, layer: layer.intValue)
        }
    }

    // AppKit's event window number is separate from the public window-under-pointer
    // fields. Window-local coordinates keep hit testing inside the hidden button,
    // while the global event location stays at the user's pointer.
    private static let eventWindowNumber = CGEventField(rawValue: 51)!
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()
    private typealias GetAXWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getAXWindow: GetAXWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetAXWindow.self)
    }()

    struct Destination {
        let window: Window
        let localPoint: CGPoint
    }

    static func hostFrameMatchesItem(_ host: CGRect, item: CGRect) -> Bool {
        // A hosted button's AX hit area can extend beyond its scene allocation
        // (Claude: 42 pt button in a 40 pt group). Match its center, with bounded
        // dimensions; full containment incorrectly rejects that visible item.
        host.width > 0 && host.height > 0 && host.height <= 60 &&
            item.width > 0 && item.height > 0 && item.height <= 60 &&
            abs(host.width - item.width) <= 32 &&
            host.contains(CGPoint(x: item.midX, y: item.midY))
    }

    /// macOS 27 publishes visible items inside a shared host window. Resolve
    /// that host through its AX group, never from a hidden item's stale frame.
    static func visibleHostDestination(for target: MenuBarProxyTarget) -> Destination? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let getAXWindow, let itemFrame = quartzFrame(of: target.accessibilityElement),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let windows = info.compactMap(Window.init(info:))
        let point = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == target.processIdentifier,
              let hitFrame = quartzFrame(of: hit), hitFrame.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        var candidates: [CGWindowID: Destination] = [:]
        for bar in elements(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute) {
            for group in elements(bar, kAXChildrenAttribute) {
                guard let frame = quartzFrame(of: group), hostFrameMatchesItem(frame, item: itemFrame) else { continue }
                let children = elements(group, kAXChildrenAttribute)
                guard children.contains(where: { child in
                    var pid: pid_t = 0
                    return AXUIElementGetPid(child, &pid) == .success && pid == target.processIdentifier
                }) else { continue }
                var id: CGWindowID = 0
                guard getAXWindow(group, &id) == .success,
                      let window = windows.first(where: { $0.id == id && $0.ownerPID == agent.processIdentifier }),
                      window.frame.contains(frame), window.frame.height <= 60 else { continue }
                candidates[id] = Destination(window: window,
                    localPoint: CGPoint(x: point.x - window.frame.minX, y: window.frame.maxY - point.y))
            }
        }
        // Space replicas refer to the same verified visible item. Prefer the
        // foremost host in WindowServer order; never click each replica in turn.
        return windows.lazy.compactMap { candidates[$0.id] }.first
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func matchingWindow(
        itemFrame: CGRect,
        targetPID: pid_t,
        hostPID: pid_t?,
        windows: [Window]
    ) -> Window? {
        guard itemFrame.width > 0, itemFrame.height > 0 else { return nil }
        let matches = windows.filter { window in
            (window.ownerPID == targetPID || window.ownerPID == hostPID) &&
                window.layer == Int(CGWindowLevelForKey(.statusWindow)) &&
                window.frame.width >= itemFrame.width && window.frame.width <= itemFrame.width + 32 &&
                window.frame.height >= itemFrame.height && window.frame.height <= 60 &&
                window.frame.insetBy(dx: -1, dy: -1).contains(itemFrame)
        }
        // Never guess between different status items or display replicas.
        return matches.count == 1 ? matches[0] : nil
    }

    static func window(for target: MenuBarProxyTarget) -> Window? {
        guard let frame = quartzFrame(of: target.accessibilityElement),
              let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let hostPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter")
            .first?.processIdentifier
        return matchingWindow(
            itemFrame: frame,
            targetPID: target.processIdentifier,
            hostPID: hostPID,
            windows: info.compactMap(Window.init(info:))
        )
    }

    @MainActor
    static func postRightClick(to target: MenuBarProxyTarget, destination prepared: Destination? = nil) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let destination = prepared ?? window(for: target).map {
            Destination(window: $0, localPoint: CGPoint(x: $0.frame.width / 2, y: $0.frame.height / 2))
        } ?? visibleHostDestination(for: target)
        guard let destination,
              let setWindowLocation,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let window = destination.window
        source.localEventsSuppressionInterval = 0

        func event(_ type: CGEventType) -> CGEvent? {
            guard let pointer = CGEvent(source: nil)?.location,
                  let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: pointer, mouseButton: .right) else { return nil }
            event.flags = []
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.ownerPID))
            event.setIntegerValueField(eventWindowNumber, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            setWindowLocation(event, destination.localPoint)
            return event
        }

        guard !Task.isCancelled, let down = event(.rightMouseDown), let up = event(.rightMouseUp) else {
            return false
        }
        // The session route lets WindowServer forward hosted status items back to
        // their owning app. postToPid alone bypasses that dispatch on macOS 26.
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Always balance mouse down, including when the request was cancelled.
        if let pointer = CGEvent(source: nil)?.location {
            up.location = pointer
            setWindowLocation(up, destination.localPoint)
        }
        up.post(tap: .cgSessionEventTap)
        NSLog("[MenuBox] Routed hidden right click target=%@ host=%d window=%u", target.displayName, window.ownerPID, window.id)
        return true
    }

    private static func quartzFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
