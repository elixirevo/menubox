import AppKit
import ApplicationServices
import CoreGraphics

enum ClickForwarder {
    enum ForwardResult {
        case accessibility
        case mouseEvent
        case failed

        var didForward: Bool {
            switch self {
            case .accessibility, .mouseEvent:
                return true
            case .failed:
                return false
            }
        }

        var title: String {
            switch self {
            case .accessibility:
                return "AXPress"
            case .mouseEvent:
                return "Mouse"
            case .failed:
                return "Failed"
            }
        }
    }

    private struct CoordinateCandidate {
        let name: String
        let point: CGPoint
    }

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func postClick(at appKitPoint: NSPoint, button: CGMouseButton, target: MenuBarProxyTarget? = nil) -> ForwardResult {
        let quartzPoint = MenuBarGeometry.quartzPoint(fromAppKitPoint: appKitPoint)
        let buttonValue = Int(button.rawValue)

        if postMouseClick(at: quartzPoint, button: button) {
            if let target {
                NSLog("[MenuBox] Forwarded proxy click with CGEvent target role=%@ title=%@ description=%@ pid=%d appKit=%@ quartz=%@ button=%ld", target.role, target.title, target.description, target.processIdentifier, NSStringFromPoint(appKitPoint), NSStringFromPoint(NSPoint(x: quartzPoint.x, y: quartzPoint.y)), buttonValue)
            } else {
                NSLog("[MenuBox] Forwarded proxy click with CGEvent at appKit=%@ quartz=%@ button=%ld", NSStringFromPoint(appKitPoint), NSStringFromPoint(NSPoint(x: quartzPoint.x, y: quartzPoint.y)), buttonValue)
            }
            return .mouseEvent
        }

        if let target,
           performAccessibilityAction(on: target.accessibilityElement, button: button, label: "live-target") {
            NSLog("[MenuBox] Forwarded proxy click with Accessibility target role=%@ title=%@ description=%@ appKit=%@ quartz=%@ button=%ld", target.role, target.title, target.description, NSStringFromPoint(appKitPoint), NSStringFromPoint(NSPoint(x: quartzPoint.x, y: quartzPoint.y)), buttonValue)
            return .accessibility
        }

        if performAccessibilityAction(at: appKitPoint, button: button) {
            NSLog("[MenuBox] Forwarded proxy click with Accessibility lookup at appKit=%@ quartz=%@ button=%ld", NSStringFromPoint(appKitPoint), NSStringFromPoint(NSPoint(x: quartzPoint.x, y: quartzPoint.y)), buttonValue)
            return .accessibility
        }

        NSLog("[MenuBox] Proxy click forwarding failed at appKit=%@ quartz=%@ button=%ld", NSStringFromPoint(appKitPoint), NSStringFromPoint(NSPoint(x: quartzPoint.x, y: quartzPoint.y)), buttonValue)
        return .failed
    }

    static func performProxyMenuItem(_ item: MenuBarProxyMenuItem) -> ForwardResult {
        let preferredActions = preferredProxyActions(from: item.actions)
        guard let element = item.accessibilityElement,
              performAccessibilityAction(on: element, preferredActions: preferredActions, label: "proxy-menu-item") else {
            NSLog("[MenuBox] Proxy menu item failed title=%@ role=%@", item.title, item.role)
            return .failed
        }

        NSLog("[MenuBox] Proxy menu item forwarded title=%@ role=%@", item.title, item.role)
        return .accessibility
    }

    static func performProxyMenuSelection(
        _ selection: MenuBarProxyMenuSelection,
        target: MenuBarProxyTarget
    ) -> ForwardResult {
        let result = performProxyMenuItem(selection.item)
        if !result.didForward {
            NSLog("[MenuBox] Proxy menu item selection failed without mouse fallback path=%@ target=%@", selection.path.joined(separator: " > "), target.displayName)
        }
        return result
    }

    static func performHiddenStatusItemAccessibilityAction(
        on target: MenuBarProxyTarget,
        button: CGMouseButton
    ) -> ForwardResult {
        if performAccessibilityAction(on: target.accessibilityElement, button: button, label: "hidden-target-native-ui") {
            NSLog("[MenuBox] Forwarded hidden status item with Accessibility only role=%@ title=%@ description=%@ pid=%d button=%ld", target.role, target.title, target.description, target.processIdentifier, Int(button.rawValue))
            return .accessibility
        }

        NSLog("[MenuBox] Hidden status item Accessibility-only action failed role=%@ title=%@ description=%@ pid=%d button=%ld", target.role, target.title, target.description, target.processIdentifier, Int(button.rawValue))
        return .failed
    }

    private static func preferredProxyActions(from actions: [String]) -> [CFString] {
        let preferredNames = [
            kAXPressAction as String,
            "AXConfirm",
            "AXPick",
            kAXShowMenuAction as String
        ]
        let availableNames = preferredNames.filter { actions.isEmpty || actions.contains($0) }
        if !availableNames.isEmpty {
            return availableNames.map { $0 as CFString }
        }
        return actions.prefix(1).map { $0 as CFString }
    }

    static func cancelProxySurface() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func postMouseClick(at quartzPoint: CGPoint, button: CGMouseButton) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp

        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: quartzPoint, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: quartzPoint, mouseButton: button) else {
            return false
        }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        CGWarpMouseCursorPosition(quartzPoint)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        Thread.sleep(forTimeInterval: 0.03)
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.025)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.045)
        up.post(tap: .cghidEventTap)

        if button == .right {
            Thread.sleep(forTimeInterval: 0.05)
            down.post(tap: .cgSessionEventTap)
            Thread.sleep(forTimeInterval: 0.045)
            up.post(tap: .cgSessionEventTap)
        }

        return true
    }

    private static func performAccessibilityAction(at appKitPoint: NSPoint, button: CGMouseButton) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        let candidates = coordinateCandidates(for: appKitPoint)

        for candidate in candidates {
            var element: AXUIElement?
            let copyError = AXUIElementCopyElementAtPosition(
                systemWide,
                Float(candidate.point.x),
                Float(candidate.point.y),
                &element
            )

            guard copyError == .success, let element else {
                NSLog("[MenuBox] AX element lookup failed coordinate=%@ point=%@ error=%@", candidate.name, NSStringFromPoint(NSPoint(x: candidate.point.x, y: candidate.point.y)), String(describing: copyError))
                continue
            }

            if performAccessibilityAction(on: element, button: button, label: candidate.name) {
                return true
            }
        }

        return false
    }

    private static func performAccessibilityAction(on element: AXUIElement, button: CGMouseButton, label: String) -> Bool {
        let preferredActions: [CFString]
        if button == .right {
            preferredActions = [kAXShowMenuAction as CFString, kAXPressAction as CFString]
        } else {
            preferredActions = [kAXPressAction as CFString, kAXShowMenuAction as CFString]
        }
        return performAccessibilityAction(on: element, preferredActions: preferredActions, label: label)
    }

    private static func performAccessibilityAction(
        on element: AXUIElement,
        preferredActions: [CFString],
        label: String
    ) -> Bool {
        for element in elementChain(startingAt: element) {
            let role = stringAttribute(kAXRoleAttribute, from: element) ?? "unknown"
            let title = stringAttribute(kAXTitleAttribute, from: element) ?? ""
            let actions = actionNames(from: element)
            NSLog("[MenuBox] AX element label=%@ role=%@ title=%@ actions=%@", label, role, title, actions.joined(separator: ","))

            for action in preferredActions {
                let actionName = action as String
                if !actions.isEmpty, !actions.contains(actionName) {
                    continue
                }
                let actionError = AXUIElementPerformAction(element, action)
                NSLog("[MenuBox] AX action label=%@ action=%@ result=%@", label, actionName, String(describing: actionError))
                if actionError == .success {
                    return true
                }
            }
        }

        return false
    }

    private static func elementChain(startingAt element: AXUIElement) -> [AXUIElement] {
        var elements = [element]
        var current = element

        for _ in 0..<3 {
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

    private static func coordinateCandidates(for appKitPoint: NSPoint) -> [CoordinateCandidate] {
        let quartzPoint = MenuBarGeometry.quartzPoint(fromAppKitPoint: appKitPoint)
        let directPoint = CGPoint(x: appKitPoint.x, y: appKitPoint.y)

        if quartzPoint == directPoint {
            return [CoordinateCandidate(name: "quartz", point: quartzPoint)]
        }

        return [
            CoordinateCandidate(name: "quartz", point: quartzPoint),
            CoordinateCandidate(name: "appkit", point: directPoint)
        ]
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

    static func openAccessibilitySettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openFullDiskAccessSettings() {
        DispatchQueue.global(qos: .userInitiated).async {
            FullDiskAccessRequest.perform(access: FullDiskAccessProbe.read()) {
                DispatchQueue.main.async {
                    openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                }
            }
        }
    }

    private static func openSystemSettings(path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }
}
