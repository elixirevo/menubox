import AppKit

/// Keep the marker registered so MenuBarAgent retains its ordering and replicas.
/// Toggling isVisible removes/reinserts it and can race the other icons' layout.
final class StatusItemMarkerPresentation {
    // macOS 27 retains this host padding even when the item's content length is
    // zero. Do not alter AppKit's private constraints: display replicas have
    // separate constraints and would otherwise collapse to different widths.
    static let collapsedHostWidth: CGFloat = 16

    private let item: NSStatusItem
    private let image: NSImage?
    private(set) var isHidden = false
    private(set) var expandedFrame: NSRect?

    init(item: NSStatusItem) {
        self.item = item
        image = item.button?.image
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden { expandedFrame = item.button?.window?.frame }
        isHidden = hidden
        item.button?.image = hidden ? nil : image
        item.button?.isEnabled = !hidden
        item.length = hidden ? 0 : NSStatusItem.squareLength
    }
}
