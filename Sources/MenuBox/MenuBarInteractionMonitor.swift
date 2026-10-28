// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit
import ApplicationServices

/// Observes user input and popup visibility only. It never opens, dismisses or
/// selects a menu, and never records keyboard input or menu contents.
final class MenuBarInteractionMonitor {
    var targetAtPoint: ((NSPoint) -> MenuBarProxyTarget?)?
    var boxFrame: (() -> NSRect?)?
    var onChange: ((Bool) -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var timer: Timer?
    private var observer: AXObserver?
    private var target: MenuBarProxyTarget?
    private var menuRoots: [AXUIElement] = []
    private var visibleBefore = Set<CGWindowID>()
    private var pressed = false
    private var settleUntil: TimeInterval = 0
    private(set) var isActive = false
    private var isEnabled = false

    func start() {
        guard localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.receive(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] in self?.receive($0) }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { reset() }
    }

    func stop() {
        reset()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isEnabled = false
    }

    deinit { stop() }

    func reset() {
        timer?.invalidate()
        timer = nil
        removeObserver()
        target = nil
        menuRoots = []
        visibleBefore = []
        pressed = false
        settleUntil = 0
        setActive(false)
    }

    /// Also used before Box forwards a click, when the actual status item may
    /// be temporarily offscreen. Baseline windows precede the forwarded input.
    func observe(_ target: MenuBarProxyTarget) {
        guard isEnabled else { return }
        removeObserver()
        self.target = target
        menuRoots = []
        visibleBefore = Set(StatusItemMenuPresentation.visibleWindows()?.map(\.id) ?? [])
        settleUntil = ProcessInfo.processInfo.systemUptime + 0.5
        setActive(true)
        installObserver(for: target)
        startPolling()
    }

    private func receive(_ event: NSEvent) {
        guard isEnabled else { return }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        if down {
            // Event coordinates, not the pointer's later position, identify the
            // clicked icon even when another process receives the event first.
            let point = event.cgEvent.map { MenuBarGeometry.appKitPoint(fromQuartzPoint: $0.location) } ?? NSEvent.mouseLocation
            if let hit = targetAtPoint?(point) {
                observe(hit)
                pressed = true
            } else if boxFrame?()?.contains(point) == true {
                pressed = true
                setActive(true)
                startPolling()
            } else if isActive {
                // Selecting a menu item or dismissing outside: do not restart
                // until release and the actual popup have both finished.
                pressed = true
            }
        } else if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type), isActive {
            pressed = false
            settleUntil = ProcessInfo.processInfo.systemUptime + 0.5
        }
        if isActive { refresh() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard isEnabled else { return }
        // The deadline can run before the asynchronous global mouse monitor.
        // Catch an in-progress press before allowing that deadline to hide.
        if !isActive, NSEvent.pressedMouseButtons != 0 {
            let point = NSEvent.mouseLocation
            if let hit = targetAtPoint?(point) {
                observe(hit)
                pressed = true
            } else if boxFrame?()?.contains(point) == true {
                pressed = true
                setActive(true)
                startPolling()
            }
        }
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Covers Command-dragging out of the menu bar and a missed mouse-up.
        if pressed, NSEvent.pressedMouseButtons == 0 {
            pressed = false
            settleUntil = now + 0.5
        }
        if pressed || NSEvent.pressedMouseButtons != 0 || now < settleUntil { return }
        if let target {
            if NSRunningApplication(processIdentifier: target.processIdentifier)?.isTerminated != false {
                reset()
                return
            }
            // An unavailable window snapshot is not proof that the menu closed.
            guard let windows = StatusItemMenuPresentation.visibleWindows() else { return }
            let anchor = MenuBarGeometry.quartzPoint(fromAppKitPoint: target.appKitClickPoint)
            if Self.hasPopup(ownerPID: target.processIdentifier, anchor: anchor, windows: windows,
                             visibleBefore: visibleBefore, accessibilityFrames: []) { return }
            let frames = MenuBarProxyScanner.statusPopupFrames(for: target, additionalRoots: menuRoots)
            if Self.hasPopup(ownerPID: target.processIdentifier, anchor: anchor, windows: windows,
                             visibleBefore: visibleBefore, accessibilityFrames: frames) { return }
        }
        reset()
    }

    static func hasPopup(ownerPID: pid_t, anchor: CGPoint, windows: [StatusItemEventRouter.Window],
                         visibleBefore: Set<CGWindowID>, accessibilityFrames: [CGRect]) -> Bool {
        windows.contains { window in
            guard window.ownerPID == ownerPID, window.frame.width >= 12, window.frame.height >= 10 else { return false }
            if MenuBarProxyScanner.isOwnedStatusMenuPopup(ownerMatchesTarget: true, layer: window.layer,
                bounds: window.frame, targetPoint: anchor) { return true }
            // Low-level custom popovers need an AX popup match. A direct click
            // may reach us after the popup appears; a nearby match is sufficient
            // even when it was already present in our initial window snapshot.
            let nearAnchor = window.frame.insetBy(dx: -80, dy: -80).contains(anchor)
            return (!visibleBefore.contains(window.id) || nearAnchor) && accessibilityFrames.contains { frame in
                abs(frame.minX - window.frame.minX) <= 8 && abs(frame.minY - window.frame.minY) <= 8 &&
                    abs(frame.width - window.frame.width) <= 16 && abs(frame.height - window.frame.height) <= 16
            }
        }
    }

    private func installObserver(for target: MenuBarProxyTarget) {
        var created: AXObserver?
        guard AXObserverCreate(target.processIdentifier, { _, element, notification, context in
            guard let context else { return }
            let monitor = Unmanaged<MenuBarInteractionMonitor>.fromOpaque(context).takeUnretainedValue()
            if notification as String == kAXMenuOpenedNotification {
                if !monitor.menuRoots.contains(where: { CFEqual($0, element) }) { monitor.menuRoots.append(element) }
            } else if notification as String == kAXMenuClosedNotification {
                monitor.menuRoots.removeAll { CFEqual($0, element) }
            }
            monitor.refresh()
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for element in [app, target.accessibilityElement] {
            for notification in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
                // Some apps do not support notifications; polling remains active.
                _ = AXObserverAddNotification(created, element, notification as CFString, context)
            }
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func removeObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange?(active)
    }
}
