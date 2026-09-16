import Foundation

/// Reads a status item's own menu without changing any visibility settings.
@MainActor
enum NativeStatusItemMenu {
    static func read(for target: MenuBarProxyTarget,
                     report: (String) -> Void = { _ in }) async -> OpenedStatusItemMenu? {
        await read(rightClick: { await StatusItemEventRouter.postRightClick(to: target) },
                   attached: { MenuBarProxyScanner.immediateProxyMenuItems(for: target) },
                   request: { MenuBarProxyScanner.requestExplicitStatusItemMenu(for: target) },
                   opened: { MenuBarProxyScanner.openedStatusItemMenu(for: target) },
                   report: {
                       NSLog("[MenuBox] Menu request %@: %@", target.bundleIdentifier, $0)
                       report($0)
                   })
    }

    static func read(rightClick: () async -> Bool = { false },
                     attached: () -> [MenuBarProxyMenuItem], request: () -> Bool,
                     opened: () -> OpenedStatusItemMenu?,
                     report: (String) -> Void = { _ in },
                     wait: () async -> Void = {
                         // A dispatched AX action cannot be recalled. Continue
                         // observing a cancelled request briefly to dismiss it.
                         await withCheckedContinuation { continuation in
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
                         }
                     }) async -> OpenedStatusItemMenu? {
        guard !Task.isCancelled else { return nil }
        // Some apps attach/rebuild their menu only in rightMouseUp. Never require
        // an existing AXMenu or an advertised AXShowMenu before trying that path.
        // The router refuses missing/ambiguous windows, including macOS 27 scenes
        // without a real status window; a frame alone is not a routing address.
        let clicked = await rightClick()
        report(clicked ? "right-click posted" : "right-click route unavailable")
        if !clicked {
            guard !Task.isCancelled else { return nil }
            let items = attached()
            if items.contains(where: { !$0.isSeparator }) { return .init(items: items, roots: []) }
            guard request() else { report("no attached menu or explicit menu action"); return nil }
            report("explicit menu action requested")
        }
        for _ in 0..<30 {
            if let menu = opened() {
                if Task.isCancelled { menu.cancel(); return nil }
                return menu
            }
            if !clicked && !Task.isCancelled {
                let items = attached()
                if items.contains(where: { !$0.isSeparator }) { return .init(items: items, roots: []) }
            }
            await wait()
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
