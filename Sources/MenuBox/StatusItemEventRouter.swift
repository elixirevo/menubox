import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// Routes a secondary click to a status item without changing the spacer or cursor.
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
    static func postRightClick(to target: MenuBarProxyTarget) async -> Bool {
        guard AXIsProcessTrusted(), let window = window(for: target),
              let setWindowLocation,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }
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
            setWindowLocation(event, CGPoint(x: window.frame.width / 2, y: window.frame.height / 2))
            return event
        }

        guard !Task.isCancelled, let down = event(.rightMouseDown), let up = event(.rightMouseUp) else {
            return false
        }
        // The session route lets WindowServer forward hosted status items back to
        // their owning app. postToPid alone bypasses that dispatch on macOS 26.
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Always balance mouse down, including when the request was cancelled.
        if let pointer = CGEvent(source: nil)?.location {
            up.location = pointer
            setWindowLocation(up, CGPoint(x: window.frame.width / 2, y: window.frame.height / 2))
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
