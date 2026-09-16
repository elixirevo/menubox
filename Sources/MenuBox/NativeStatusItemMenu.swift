import Foundation
import CoreGraphics

/// Reads a status item's own menu without changing any visibility settings.
@MainActor
enum NativeStatusItemMenu {
    /// Keep the original popup and selected-app visibility alive until the
    /// native app handles selection/dismissal. No proxy or second click follows.
    static func keepVisibleUntilClosed(_ menu: OpenedStatusItemMenu,
                                      isVisible: () -> Bool,
                                      wait: () async -> Void = {
                                          try? await Task.sleep(nanoseconds: 50_000_000)
                                      }) async {
        while !Task.isCancelled {
            guard isVisible() else { menu.finish(); return }
            await wait()
        }
        menu.cancel()
    }

    static func read(for target: MenuBarProxyTarget,
                     destination: StatusItemEventRouter.Destination? = nil,
                     report: (String) -> Void = { _ in }) async -> OpenedStatusItemMenu? {
        var popupPoint: CGPoint?
        return await read(rightClick: {
                       let pointer = CGEvent(source: nil)?.location
                       let posted = await StatusItemEventRouter.postRightClick(to: target, destination: destination)
                       if posted { popupPoint = pointer }
                       return posted
                   },
                   attached: { MenuBarProxyScanner.immediateProxyMenuItems(for: target) },
                   request: { MenuBarProxyScanner.requestExplicitStatusItemMenu(for: target) },
                   opened: { MenuBarProxyScanner.openedStatusItemMenu(for: target, popupPoint: popupPoint) },
                   report: {
                       NSLog("[MenuBox] Menu request %@: %@", target.bundleIdentifier, $0)
                       report($0)
                   })
    }

    static func read(rightClick: () async -> Bool = { false },
                     attached: () -> [MenuBarProxyMenuItem], request: () -> Bool,
                     opened: () -> OpenedStatusItemMenu?,
                     report: (String) -> Void = { _ in },
                     wait: (() async -> Void)? = nil) async -> OpenedStatusItemMenu? {
        guard !Task.isCancelled else { return nil }
        // Read the app's current attached menu before sending any input. This
        // avoids highlighting a visible status icon and opening a source popup
        // solely to copy a menu that the app already exposes. Never cache it:
        // presentation and selection each call attached() on the live target.
        let available = attached()
        guard !Task.isCancelled else { return nil }
        if available.contains(where: { !$0.isSeparator }) {
            report("attached menu read without input")
            return .init(items: available, roots: [])
        }
        // No attached menu is not a failure. Dynamic apps can create it only
        // in rightMouseUp, even without an advertised AXShowMenu action.
        // The router refuses missing/ambiguous windows, including macOS 27 scenes
        // without a real status window; a frame alone is not a routing address.
        let clicked = await rightClick()
        report(clicked ? "right-click posted" : "right-click route unavailable")
        if !clicked {
            guard !Task.isCancelled else { return nil }
            // Routing may take time; an attached menu can appear meanwhile.
            let items = attached()
            if items.contains(where: { !$0.isSeparator }) { return .init(items: items, roots: []) }
            guard request() else { report("no attached menu or explicit menu action"); return nil }
            report("explicit menu action requested")
        }
        for attempt in 0..<30 {
            if let menu = opened() {
                if Task.isCancelled { menu.cancel(); return nil }
                return menu
            }
            if !clicked && !Task.isCancelled {
                let items = attached()
                if items.contains(where: { !$0.isSeparator }) { return .init(items: items, roots: []) }
            }
            if let wait { await wait() }
            else {
                // Observe fast menus promptly while retaining a 1.5 second
                // total budget for slower apps. Cancellation still observes
                // late popups long enough to dismiss a dispatched request.
                let delay = attempt < 10 ? 0.01 : 0.07
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { continuation.resume() }
                }
            }
        }
        if clicked && !Task.isCancelled {
            // Do not race a posted click with an old, still-attached menu. Only
            // use that fallback after the native popup observation has finished.
            let items = attached()
            if items.contains(where: { !$0.isSeparator }) { return .init(items: items, roots: []) }
        }
        report("menu observation timed out")
        return nil
    }
}
