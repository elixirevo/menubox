import AppKit
import CoreGraphics

/// Identifies the actual app-owned popup, so it can remain interactive at Box.
struct StatusItemMenuPresentation {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect // Quartz coordinates

    var isVisible: Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
        }
    }

    static func isBesideBox(menu: CGRect, box: CGRect, anchor: CGPoint) -> Bool {
        // All three arguments use Quartz coordinates. The popup must start in
        // the Box area; the pointer may move within Box while the app responds.
        // A menu hanging from the menu bar is not adopted.
        box.insetBy(dx: -4, dy: -4).contains(anchor) &&
            menu.minY >= box.minY - 4 && menu.minY <= box.maxY + 8 &&
            menu.intersects(box.insetBy(dx: -24, dy: -24))
    }
}
