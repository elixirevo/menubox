// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import AppKit

/// Keep the marker registered so MenuBarAgent retains its ordering and replicas.
/// Toggling isVisible removes/reinserts it and can race the other icons' layout.
final class StatusItemMarkerPresentation {
    // macOS 27 retains this host padding even when the item's content length is
    // zero. Do not alter AppKit's private constraints: display replicas have
    // separate constraints and would otherwise collapse to different widths.
    static let collapsedHostWidth: CGFloat = 16

    private let item: NSStatusItem
    private(set) var isHidden = false
    private(set) var expandedFrame: NSRect?

    init(item: NSStatusItem) {
        self.item = item
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden { expandedFrame = item.button?.window?.frame }
        isHidden = hidden
        // Submit only a geometry change to the hosted menu bar. Clearing the
        // image redraws the client surface before MenuBarAgent applies the other
        // icons' visibility, while waiting for AX removal makes this item late.
        // At zero content length AppKit clips the intact image to a zero-width
        // button. Keeping its image and enabled state also avoids a separate
        // redraw when revealing it. The host retains its usual padding.
        item.length = hidden ? 0 : NSStatusItem.squareLength
    }
}
